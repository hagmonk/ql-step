use std::collections::{HashMap, HashSet};
use std::convert::TryInto;

use nalgebra_glm as glm;
use glm::{DVec3, DVec4, DMat4, U32Vec3};
use log::{info, warn, error};

#[cfg(feature = "rayon")]
use rayon::prelude::*;

use step::{
    ap214, ap214::*, step_file::{FromEntity, StepFile}, id::Id, ap214::Entity,
};
use crate::{
    Error,
    curve::Curve,
    mesh, mesh::{Mesh, Triangle},
    stats::Stats,
    surface::Surface
};
use nurbs::{BSplineSurface, SampledCurve, SampledSurface, NURBSSurface, KnotVector};

const SAVE_DEBUG_SVGS: bool = false;
const SAVE_PANIC_SVGS: bool = false;

/// `TransformStack` maps representation ids to transformed children.
/// Keys are raw entity ids so that plain-SRR merging (union-find) can
/// canonicalize them.
type TransformStack = HashMap<usize, Vec<(usize, DMat4)>>;

/// Union-find over raw entity ids, used to merge representations related by
/// plain SHAPE_REPRESENTATION_RELATIONSHIPs (no transform), which declare
/// that two representations describe the same shape in the same frame.
/// OCCT transfers both sides of such a relationship ("on prend les 2",
/// STEPControl_ActorRead::TransferEntity); merging makes the traversal reach
/// geometry on either side regardless of argument order.
fn uf_find(uf: &mut HashMap<usize, usize>, x: usize) -> usize {
    let mut root = x;
    while let Some(&p) = uf.get(&root) {
        if p == root { break; }
        root = p;
    }
    let mut cur = x;
    while cur != root {
        let p = uf[&cur];
        uf.insert(cur, root);
        cur = p;
    }
    root
}

fn uf_union(uf: &mut HashMap<usize, usize>, a: usize, b: usize) {
    let ra = uf_find(uf, a);
    let rb = uf_find(uf, b);
    if ra != rb {
        uf.insert(ra, rb);
    }
}

/// Maps each representation to its PRODUCT_DEFINITION by walking
/// SHAPE_DEFINITION_REPRESENTATION -> PRODUCT_DEFINITION_SHAPE (or plain
/// PROPERTY_DEFINITION) -> definition. Mirrors the lookup in OCCT's
/// STEPConstruct_Assembly::CheckSRRReversesNAUO.
fn rep_product_definitions(s: &StepFile) -> HashMap<usize, usize> {
    let mut out = HashMap::new();
    for sdr in s.0.iter()
        .filter_map(ShapeDefinitionRepresentation_::try_from_entity)
    {
        let pd = s.entity(sdr.definition.cast::<ProductDefinitionShape_>())
            .map(|pds| pds.definition.0)
            .or_else(|| s.entity(sdr.definition.cast::<PropertyDefinition_>())
                .map(|p| p.definition.0));
        if let Some(pd) = pd {
            out.insert(sdr.used_representation.0, pd);
        }
    }
    out
}

/// True if `item` appears in the representation's item list.
fn rep_contains_item(s: &StepFile, rep: Representation, item: usize) -> bool {
    match &s[rep] {
        Entity::ShapeRepresentation(b) =>
            b.items.iter().any(|i| i.0 == item),
        Entity::AdvancedBrepShapeRepresentation(b) =>
            b.items.iter().any(|i| i.0 == item),
        Entity::ManifoldSurfaceShapeRepresentation(b) =>
            b.items.iter().any(|i| i.0 == item),
        _ => false,
    }
}

/// Computes the instance transform for a RRWT, validating that each axis
/// placement of the ITEM_DEFINED_TRANSFORMATION belongs to its declared
/// representation and inverting when both are crossed — the same per-edge
/// correction OCCT applies in STEPControl_ActorRead::ComputeTransformation
/// (": abv 31.10.01: TEST_MCI_2.step").
fn checked_item_defined_transformation(
    s: &StepFile, r: &RepresentationRelationshipWithTransformation_,
) -> DMat4 {
    let mat = item_defined_transformation(s, r.transformation_operator.cast());
    if let Some(idt) = s.entity(
        r.transformation_operator.cast::<ItemDefinedTransformation_>())
    {
        let i1 = idt.transform_item_1.0;
        let i2 = idt.transform_item_2.0;
        let swapped =
            !rep_contains_item(s, r.rep_1, i1)
            && !rep_contains_item(s, r.rep_2, i2)
            && rep_contains_item(s, r.rep_1, i2)
            && rep_contains_item(s, r.rep_2, i1);
        if swapped {
            warn!("Axis placements are swapped in RRWT; corrected");
            return mat.try_inverse()
                .expect("Could not invert swapped transform matrix");
        }
    }
    mat
}

/// Builds parent -> (child, transform) edges. For relationships wrapped in a
/// CONTEXT_DEPENDENT_SHAPE_REPRESENTATION the parent/child orientation comes
/// from the NEXT_ASSEMBLY_USAGE_OCCURRENCE product hierarchy (relating =
/// assembly, related = component) exactly as OCCT does, instead of trusting
/// SRR argument order. Returns the stack plus whether any NAUO-backed edge
/// was found (files without them keep the legacy multiple-roots flip).
fn build_transform_stack(s: &StepFile) -> (TransformStack, bool) {
    let rep_pd = rep_product_definitions(s);
    let mut stack: TransformStack = HashMap::new();
    let mut covered: HashSet<usize> = HashSet::new();
    let mut nauo_oriented = false;

    for cdsr in s.0.iter()
        .filter_map(ContextDependentShapeRepresentation_::try_from_entity)
    {
        let rr = cdsr.representation_relation;
        let Some(rrwt) = s.entity(
            rr.cast::<RepresentationRelationshipWithTransformation_>())
        else { continue };
        covered.insert(rr.0);

        let mut mat = checked_item_defined_transformation(s, rrwt);
        // Default per ISO 10303: rep_1 is the component, rep_2 the assembly
        let (mut parent, mut child) = (rrwt.rep_2, rrwt.rep_1);
        if let Some(nauo) = s.entity(cdsr.represented_product_relation)
            .and_then(|pds| s.entity(
                pds.definition.cast::<NextAssemblyUsageOccurrence_>()))
        {
            nauo_oriented = true;
            let related = nauo.related_product_definition.0;
            let relating = nauo.relating_product_definition.0;
            if rep_pd.get(&rrwt.rep_2.0) == Some(&related)
                && rep_pd.get(&rrwt.rep_1.0) == Some(&relating)
            {
                warn!("SRR reverses relation defined by NAUO; \
                       NAUO definition is taken");
                parent = rrwt.rep_1;
                child = rrwt.rep_2;
                mat = mat.try_inverse()
                    .expect("Could not invert reversed transform matrix");
            }
        }
        stack.entry(parent.0).or_default().push((child.0, mat));
    }

    // RRWTs not wrapped in any CDSR keep the legacy rep_2 -> rep_1 edge
    for (i, rrwt) in s.0.iter().enumerate()
        .filter_map(|(i, e)|
            RepresentationRelationshipWithTransformation_::try_from_entity(e)
                .map(|r| (i, r)))
    {
        if covered.contains(&i) { continue; }
        let mat = checked_item_defined_transformation(s, rrwt);
        stack.entry(rrwt.rep_2.0).or_default().push((rrwt.rep_1.0, mat));
    }
    (stack, nauo_oriented)
}

fn transform_stack_roots(transform_stack: &TransformStack) -> Vec<usize> {
    let children: HashSet<usize> = transform_stack
        .values()
        .flat_map(|v| v.iter())
        .map(|v| v.0)
        .collect();
    transform_stack
        .keys()
        .filter(|k| !children.contains(k))
        .copied()
        .collect()
}

pub fn triangulate(s: &StepFile) -> (Mesh, Stats) {
    // Collect every STYLED_ITEM in the file, not just the ones reachable via
    // MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION. Targets are
    // commonly individual ADVANCED_FACEs, not just whole solids, so key the
    // map by raw entity id and let lookups happen at both granularities.
    let item_colors: HashMap<usize, DVec3> = s.0.iter()
        .filter_map(StyledItem_::try_from_entity)
        .filter_map(|styled| {
            styled.styles.iter()
                .find_map(|style| presentation_style_color(s, *style))
                .map(|c| (styled.item.0, c))
        })
        .collect();

    // Parent -> (child, transform) edges, oriented by the NAUO product
    // hierarchy where the file provides one
    let (raw_stack, nauo_oriented) = build_transform_stack(s);

    // Merge representations related by plain (transform-free) SRRs into
    // components; both sides describe the same shape in the same frame
    let mut uf: HashMap<usize, usize> = HashMap::new();
    let mut rep_ids: HashSet<usize> = HashSet::new();
    for srr in s.0.iter()
        .filter_map(ShapeRepresentationRelationship_::try_from_entity)
    {
        uf_union(&mut uf, srr.rep_1.0, srr.rep_2.0);
        rep_ids.insert(srr.rep_1.0);
        rep_ids.insert(srr.rep_2.0);
    }
    for (parent, children) in &raw_stack {
        rep_ids.insert(*parent);
        for (child, _) in children {
            rep_ids.insert(*child);
        }
    }
    let mut members: HashMap<usize, Vec<usize>> = HashMap::new();
    for id in &rep_ids {
        members.entry(uf_find(&mut uf, *id)).or_default().push(*id);
    }

    // Canonicalize the transform stack onto component representatives
    let mut transform_stack: TransformStack = HashMap::new();
    for (parent, children) in raw_stack {
        let p = uf_find(&mut uf, parent);
        for (child, mat) in children {
            let c = uf_find(&mut uf, child);
            if c != p {
                transform_stack.entry(p).or_default().push((c, mat));
            }
        }
    }

    let mut roots = transform_stack_roots(&transform_stack);
    // Files that don't provide a NAUO product hierarchy give no reliable
    // edge orientation; keep the legacy heuristic of flipping the whole
    // graph when it has multiple roots.
    if roots.len() > 1 && !nauo_oriented {
        info!("Flipping transform stack");
        let mut flipped: TransformStack = HashMap::new();
        for (parent, children) in transform_stack {
            for (child, mat) in children {
                let inv = mat.try_inverse()
                    .expect("Could not invert transform matrix");
                flipped.entry(child).or_default().push((parent, inv));
            }
        }
        transform_stack = flipped;
        roots = transform_stack_roots(&transform_stack);
    }
    let mut todo: Vec<(usize, DMat4)> = roots.into_iter()
        .map(|v| (v, DMat4::identity()))
        .collect();
    if todo.len() > 1 {
        warn!("Transformation stack has more than one root!");
    }

    let mut to_mesh: HashMap<Id<_>, Vec<_>> = HashMap::new();
    while let Some((cid, mat)) = todo.pop() {
        if let Some(children) = transform_stack.get(&cid) {
            for (child, next_mat) in children {
                todo.push((*child, mat * next_mat));
            }
        }
        // Bind mesh-bearing items of every representation in this component
        // (assemblies may carry their own geometry alongside child instances)
        let singleton = [cid];
        let component = members.get(&cid)
            .map(|v| v.as_slice())
            .unwrap_or(&singleton);
        for rep in component {
            let rep: Representation = Id::new(*rep);
            let items = match &s[rep] {
                Entity::AdvancedBrepShapeRepresentation(b) => &b.items,
                Entity::ShapeRepresentation(b) => &b.items,
                Entity::ManifoldSurfaceShapeRepresentation(b) => &b.items,
                _ => continue,
            };

            for m in items.iter() {
                match &s[*m] {
                    Entity::ManifoldSolidBrep(_)
                    | Entity::BrepWithVoids(_)
                    | Entity::ShellBasedSurfaceModel(_) =>
                        to_mesh.entry(*m).or_default().push(mat),
                    Entity::Axis2Placement3d(_) => (),
                    e => warn!("Skipping {:?}", e),
                }
            }
        }
    }
    // If there are items in breps that aren't attached to a transformation
    // chain, then draw them individually (with an identity matrix)
    if to_mesh.is_empty() {
        s.0.iter()
            .enumerate()
            .filter(|(_i, e)|
                match e {
                    Entity::ManifoldSolidBrep(_)
                    | Entity::BrepWithVoids(_)
                    | Entity::ShellBasedSurfaceModel(_) => true,
                    _ => false,
                }
            )
            .map(|(i, _e)| Id::new(i))
            .for_each(|i| to_mesh.entry(i).or_default().push(DMat4::identity()));
    }

    let (to_mesh_iter, empty) = {
        #[cfg(feature = "rayon")]
        { (to_mesh.par_iter(), || (Mesh::default(), Stats::default())) }
        #[cfg(not(feature = "rayon"))]
        { (to_mesh.iter(), (Mesh::default(), Stats::default())) }
    };
    let mesh_fold = to_mesh_iter
        .fold(
            // Empty constructor
            empty,

            // Fold operation
            |(mut mesh, mut stats), (id, mats)| {
                let v_start = mesh.verts.len();
                let t_start = mesh.triangles.len();

                // The solid-level style, if any, is the default; individual
                // faces styled directly override it inside the shell walkers.
                let color = item_colors.get(&id.0)
                    .map(|c| *c)
                    .unwrap_or(DVec3::new(0.5, 0.5, 0.5));

                match &s[*id] {
                    Entity::ManifoldSolidBrep(b) =>
                        closed_shell(s, b.outer, &mut mesh, &mut stats,
                                     &item_colors, color),
                    Entity::ShellBasedSurfaceModel(b) =>
                        for v in &b.sbsm_boundary {
                            shell(s, *v, &mut mesh, &mut stats,
                                  &item_colors, color);
                        },
                    Entity::BrepWithVoids(b) =>
                        // TODO: handle voids
                        closed_shell(s, b.outer, &mut mesh, &mut stats,
                                     &item_colors, color),
                    _ => {
                        warn!("Skipping {:?} (not a known solid)", s[*id]);
                        return (mesh, stats);
                    },
                };

                // Build copies of the mesh by copying and applying transforms
                let v_end = mesh.verts.len();
                let t_end = mesh.triangles.len();
                for mat in &mats[1..] {
                    for v in v_start..v_end {
                        let p = mesh.verts[v].pos;
                        let p_h = DVec4::new(p.x, p.y, p.z, 1.0);
                        let pos = (mat * p_h).xyz();

                        let n = mesh.verts[v].norm;
                        let norm = (mat * glm::vec3_to_vec4(&n)).xyz();

                        let color = mesh.verts[v].color;
                        mesh.verts.push(mesh::Vertex { pos, norm, color });
                    }
                    let offset = mesh.verts.len() - v_end;
                    for t in t_start..t_end {
                        let mut tri = mesh.triangles[t];
                        tri.verts.add_scalar_mut(offset as u32);
                        mesh.triangles.push(tri);
                    }
                }

                // Now that we've built all of the other copies of the mesh,
                // re-use the original mesh and apply the first transform
                let mat = mats[0];
                for v in v_start..v_end {
                    let p = mesh.verts[v].pos;
                    let p_h = DVec4::new(p.x, p.y, p.z, 1.0);
                    mesh.verts[v].pos = (mat * p_h).xyz();

                    let n = mesh.verts[v].norm;
                    mesh.verts[v].norm = (mat * glm::vec3_to_vec4(&n)).xyz();
                }
                (mesh, stats)
            });

    let (mesh, stats) = {
        #[cfg(feature = "rayon")]
        { mesh_fold.reduce(empty,
                |a, b| (Mesh::combine(a.0, b.0), Stats::combine(a.1, b.1))) }
        #[cfg(not(feature = "rayon"))]
        {
            mesh_fold
        }
    };

    info!("num_shells: {}", stats.num_shells);
    info!("num_faces: {}", stats.num_faces);
    info!("num_errors: {}", stats.num_errors);
    info!("num_panics: {}", stats.num_panics);
    (mesh, stats)
}

fn item_defined_transformation(s: &StepFile, t: Id<ItemDefinedTransformation_>) -> DMat4 {
    let i = s.entity(t).expect("Could not get ItemDefinedTransform");

    let (location, axis, ref_direction) = axis2_placement_3d(s,
        i.transform_item_1.cast());
    let t1 = Surface::make_affine_transform(axis,
        ref_direction,
        axis.cross(&ref_direction),
        location);

    let (location, axis, ref_direction) = axis2_placement_3d(s,
        i.transform_item_2.cast());
    let t2 = Surface::make_affine_transform(axis,
        ref_direction,
        axis.cross(&ref_direction),
        location);

    t2 * t1.try_inverse().expect("Could not invert transform matrix")
}

fn presentation_style_color(s: &StepFile, p: PresentationStyleAssignment)
    -> Option<DVec3>
{
    // Walk PRESENTATION_STYLE_ASSIGNMENT -> SURFACE_STYLE_USAGE ->
    // SURFACE_SIDE_STYLE -> SURFACE_STYLE_FILL_AREA -> FILL_AREA_STYLE ->
    // FILL_AREA_STYLE_COLOUR -> COLOUR_RGB, scanning every style at each
    // level instead of bailing when an assignment carries more than one
    // (files routinely pair a fill style with a curve style).
    s.entity(p)?.styles.iter()
        .filter_map(|y| {
            // This is an ambiguous parse, so we hard-code the first
            // Entity item in the enum
            use PresentationStyleSelect::PreDefinedPresentationStyle;
            if let PreDefinedPresentationStyle(u) = y {
                s.entity(u.cast::<SurfaceStyleUsage_>())
            } else {
                None
            }})
        .filter_map(|surf: &SurfaceStyleUsage_|
            s.entity(surf.style.cast::<SurfaceSideStyle_>()))
        .flat_map(|side: &SurfaceSideStyle_| side.styles.iter())
        .filter_map(|style|
            s.entity(style.cast::<SurfaceStyleFillArea_>()))
        .filter_map(|surf: &SurfaceStyleFillArea_|
            s.entity(surf.fill_area))
        .flat_map(|fill: &FillAreaStyle_| fill.fill_styles.iter())
        .filter_map(|fs| s.entity(fs.cast::<FillAreaStyleColour_>()))
        .filter_map(|f: &FillAreaStyleColour_|
            s.entity(f.fill_colour.cast::<ColourRgb_>()))
        .map(|c| DVec3::new(c.red, c.green, c.blue))
        .next()
}

fn cartesian_point(s: &StepFile, a: Id<CartesianPoint_>) -> DVec3 {
    let p = s.entity(a).expect("Could not get cartesian point");
    DVec3::new(p.coordinates[0].0, p.coordinates[1].0, p.coordinates[2].0)
}

fn direction(s: &StepFile, a: Direction) -> DVec3 {
    let p = s.entity(a).expect("Could not get cartesian point");
    DVec3::new(p.direction_ratios[0],
               p.direction_ratios[1],
               p.direction_ratios[2])
}

fn axis2_placement_3d(s: &StepFile, t: Id<Axis2Placement3d_>) -> (DVec3, DVec3, DVec3) {
    let a = s.entity(t).expect("Could not get Axis2Placement3d");
    let location = cartesian_point(s, a.location);
    // TODO: this doesn't necessarily match the behavior of `build_axes`
    let axis = direction(s, a.axis.expect("Missing axis"));
    let ref_direction = match a.ref_direction {
        None => DVec3::new(1.0, 0.0, 0.0),
        Some(r) => direction(s, r),
    };
    (location, axis, ref_direction)
}

fn shell(s: &StepFile, c: Shell, mesh: &mut Mesh, stats: &mut Stats,
         colors: &HashMap<usize, DVec3>, default_color: DVec3) {
    match &s[c] {
        Entity::ClosedShell(_) =>
            closed_shell(s, c.cast(), mesh, stats, colors, default_color),
        Entity::OpenShell(_) =>
            open_shell(s, c.cast(), mesh, stats, colors, default_color),
        h => warn!("Skipping {:?} (unknown Shell type)", h),
    }
}

fn open_shell(s: &StepFile, c: OpenShell, mesh: &mut Mesh, stats: &mut Stats,
              colors: &HashMap<usize, DVec3>, default_color: DVec3) {
    let cs = s.entity(c).expect("Could not get OpenShell");
    for face in &cs.cfs_faces {
        face_with_color(s, *face, mesh, stats, colors, default_color);
    }
    stats.num_shells += 1;
}

fn closed_shell(s: &StepFile, c: ClosedShell, mesh: &mut Mesh, stats: &mut Stats,
                colors: &HashMap<usize, DVec3>, default_color: DVec3) {
    let cs = s.entity(c).expect("Could not get ClosedShell");
    for face in &cs.cfs_faces {
        face_with_color(s, *face, mesh, stats, colors, default_color);
    }
    stats.num_shells += 1;
}

/// Triangulates one face, then paints its new vertices with the face's own
/// STYLED_ITEM color when present, falling back to the parent solid's color.
fn face_with_color(s: &StepFile, face: Face, mesh: &mut Mesh, stats: &mut Stats,
                   colors: &HashMap<usize, DVec3>, default_color: DVec3) {
    let v_start = mesh.verts.len();
    if let Err(err) = advanced_face(s, face.cast(), mesh, stats) {
        error!("Failed to triangulate {:?}: {}", s[face], err);
    }
    let color = colors.get(&face.0).copied().unwrap_or(default_color);
    for v in &mut mesh.verts[v_start..] {
        v.color = color;
    }
}

fn advanced_face(s: &StepFile, f: AdvancedFace, mesh: &mut Mesh,
                 stats: &mut Stats) -> Result<(), Error>
{
    let face = s.entity(f).expect("Could not get AdvancedFace");
    stats.num_faces += 1;

    // Grab the surface, returning early if it's unimplemented
    let mut surf = get_surface(s, face.face_geometry)?;

    // This is the starting point at which we insert new vertices
    let offset = mesh.verts.len();

    // For each contour, project from 3D down to the surface, then
    // start collecting them as constrained edges for triangulation
    let mut edges = Vec::new();
    let v_start = mesh.verts.len();
    let mut num_pts = 0;
    for b in &face.bounds {
        let bound_contours = face_bound(s, *b)?;

        match bound_contours.len() {
            // We should always have non-zero items in the contour
            0 => panic!("Got empty contours for {:?}", face),

            // Special case for a single-vertex point, which shows up in
            // cones: we push it as a Steiner point, but without any
            // associated contours.
            1 => {
                num_pts += 1;
                mesh.verts.push(mesh::Vertex {
                    pos: bound_contours[0],
                    norm: DVec3::zeros(),
                    color: DVec3::new(0.0, 0.0, 0.0),
                });
            },

            // Default for lists of contour points
            _ => {
                // Record the initial point to close the loop
                let start = num_pts;
                for pt in bound_contours {
                    // The contour marches forward!
                    edges.push((num_pts, num_pts + 1));

                    // Also store this vertex in the 3D triangulation
                    mesh.verts.push(mesh::Vertex {
                        pos: pt,
                        norm: DVec3::zeros(),
                        color: DVec3::new(0.0, 0.0, 0.0),
                    });
                    num_pts += 1;
                }
                // The last point is a duplicate, because it closes the
                // contours, so we skip it here and reattach the contour to
                // the start.
                num_pts -= 1;
                mesh.verts.pop();

                // Close the loop by returning to the starting point
                edges.pop();
                edges.last_mut().unwrap().1 = start;
            }
        }
    }

    // We inject Stiner points based on the surface type to improve curvature,
    // e.g. for spherical sections.  However, we don't want triagulation to
    // _fail_ due to these points, so if that happens, we nuke the point (by
    // assigning it to the first point in the list, which causes it to get
    // deduplicated), then retry.
    let mut pts = surf.lower_verts(&mut mesh.verts[v_start..])?;
    let bonus_points = pts.len();
    surf.add_steiner_points(&mut pts, &mut mesh.verts);
    let result = std::panic::catch_unwind(|| {
        // TODO: this is only needed because we use pts below to save a debug
        // SVG if this panics.  Once we're confident in never panicking, we
        // can remove this.
        let mut pts = pts.clone();
        loop {
            let mut t = match cdt::Triangulation::new_with_edges(&pts, &edges) {
                Err(e) => break Err(e),
                Ok(t) => t,
            };
            match t.run() {
                Ok(()) => break Ok(t),
                // If triangulation failed due to a Steiner point on a fixed
                // edge, then reassign that point to pts[0] (so it will be
                // ignored as a duplicate)
                Err(cdt::Error::PointOnFixedEdge(p)) if p >= bonus_points => {
                    pts[p] = pts[0];
                    continue;
                },
                Err(e) => {
                    if SAVE_DEBUG_SVGS {
                        let filename = format!("err{}.svg", face.face_geometry.0);
                        t.save_debug_svg(&filename)
                            .expect("Could not save debug SVG");
                    }
                    break Err(e)
                },
            }
        }
    });
    match result {
        Ok(Ok(t)) => {
            for (a, b, c) in t.triangles() {
                let a = (a + offset) as u32;
                let b = (b + offset) as u32;
                let c = (c + offset) as u32;
                mesh.triangles.push(Triangle { verts:
                    if face.same_sense {
                        U32Vec3::new(a, b, c)
                    } else {
                        U32Vec3::new(a, c, b)
                    }
                });
            }
        },
        Ok(Err(e)) => {
            error!("Got error while triangulating {}: {:?}",
                   face.face_geometry.0, e);
            stats.num_errors += 1;
        },
        Err(e) => {
            error!("Got panic while triangulating {}: {:?}",
                   face.face_geometry.0, e);
            if SAVE_PANIC_SVGS {
                let filename = format!("panic{}.svg", face.face_geometry.0);
                cdt::save_debug_panic(&pts, &edges, &filename)
                    .expect("Could not save debug SVG");
            }
            stats.num_panics += 1;
        }
    }
    // Flip normals of new vertices, depending on the same_sense flag
    if !face.same_sense {
        for v in &mut mesh.verts[v_start..] {
            v.norm = -v.norm;
        }
    }
    Ok(())
}

fn get_surface(s: &StepFile, surf: ap214::Surface) -> Result<Surface, Error> {
    match &s[surf] {
        Entity::CylindricalSurface(c) => {
            let (location, axis, ref_direction) = axis2_placement_3d(s, c.position);
            Ok(Surface::new_cylinder(axis, ref_direction, location, c.radius.0.0.0))
        },
        Entity::ToroidalSurface(c) => {
            let (location, axis, _ref_direction) = axis2_placement_3d(s, c.position);
            Ok(Surface::new_torus(location, axis, c.major_radius.0.0.0, c.minor_radius.0.0.0))
        },
        Entity::Plane(p) => {
            // We'll ignore axis and ref_direction in favor of building an
            // orthonormal basis later on
            let (location, axis, ref_direction) = axis2_placement_3d(s, p.position);
            Ok(Surface::new_plane(axis, ref_direction, location))
        },
        // We treat cones like planes, since that's a valid mapping into 2D
        Entity::ConicalSurface(c) => {
            let (location, axis, ref_direction) = axis2_placement_3d(s, c.position);
            Ok(Surface::new_cone(axis, ref_direction, location, c.semi_angle.0))
        },
        Entity::SphericalSurface(c) => {
            // We'll ignore axis and ref_direction in favor of building an
            // orthonormal basis later on
            let (location, _axis, _ref_direction) = axis2_placement_3d(s, c.position);
            Ok(Surface::new_sphere(location, c.radius.0.0.0))
        },
        Entity::BSplineSurfaceWithKnots(b) =>
        {
            // TODO: make KnotVector::from_multiplicies accept iterators?
            let u_knots: Vec<f64> = b.u_knots.iter().map(|k| k.0).collect();
            let u_multiplicities: Vec<usize> = b.u_multiplicities.iter()
                .map(|&k| k.try_into().expect("Got negative multiplicity"))
                .collect();
            let u_knot_vec = KnotVector::from_multiplicities(
                b.u_degree.try_into().expect("Got negative degree"),
                &u_knots, &u_multiplicities);

            let v_knots: Vec<f64> = b.v_knots.iter().map(|k| k.0).collect();
            let v_multiplicities: Vec<usize> = b.v_multiplicities.iter()
                .map(|&k| k.try_into().expect("Got negative multiplicity"))
                .collect();
            let v_knot_vec = KnotVector::from_multiplicities(
                b.v_degree.try_into().expect("Got negative degree"),
                &v_knots, &v_multiplicities);

            let control_points_list = control_points_2d(s, &b.control_points_list);

            let surf = BSplineSurface::new(
                b.u_closed.0.unwrap() == false,
                b.v_closed.0.unwrap() == false,
                u_knot_vec,
                v_knot_vec,
                control_points_list,
            );
            Ok(Surface::BSpline(SampledSurface::new(surf)))
        },
        Entity::ComplexEntity(v) if v.len() == 2 => {
            let bspline = if let Entity::BSplineSurfaceWithKnots(b) = &v[0] {
                b
            } else {
                warn!("Could not get BSplineCurveWithKnots from {:?}", v[0]);
                return Err(Error::UnknownCurveType)
            };
            let rational = if let Entity::RationalBSplineSurface(b) = &v[1] {
                b
            } else {
                warn!("Could not get RationalBSplineCurve from {:?}", v[1]);
                return Err(Error::UnknownCurveType)
            };

            // TODO: make KnotVector::from_multiplicies accept iterators?
            let u_knots: Vec<f64> = bspline.u_knots.iter().map(|k| k.0).collect();
            let u_multiplicities: Vec<usize> = bspline.u_multiplicities.iter()
                .map(|&k| k.try_into().expect("Got negative multiplicity"))
                .collect();
            let u_knot_vec = KnotVector::from_multiplicities(
                bspline.u_degree.try_into().expect("Got negative degree"),
                &u_knots, &u_multiplicities);

            let v_knots: Vec<f64> = bspline.v_knots.iter().map(|k| k.0).collect();
            let v_multiplicities: Vec<usize> = bspline.v_multiplicities.iter()
                .map(|&k| k.try_into().expect("Got negative multiplicity"))
                .collect();
            let v_knot_vec = KnotVector::from_multiplicities(
                bspline.v_degree.try_into().expect("Got negative degree"),
                &v_knots, &v_multiplicities);

            let control_points_list = control_points_2d(
                    s, &bspline.control_points_list)
                .into_iter()
                .zip(rational.weights_data.iter())
                .map(|(ctrl, weight)|
                    ctrl.into_iter()
                        .zip(weight.into_iter())
                        .map(|(p, w)| DVec4::new(p.x * w, p.y * w, p.z * w, *w))
                        .collect())
                .collect();

            let surf = NURBSSurface::new(
                bspline.u_closed.0.unwrap() == false,
                bspline.v_closed.0.unwrap() == false,
                u_knot_vec,
                v_knot_vec,
                control_points_list,
            );
            Ok(Surface::NURBS(SampledSurface::new(surf)))

        },
        e => {
            warn!("Could not get surface from {:?}", e);
            Err(Error::UnknownSurfaceType)
        },
    }
}

fn control_points_1d(s: &StepFile, row: &Vec<CartesianPoint>) -> Vec<DVec3> {
    row.iter().map(|p| cartesian_point(s, *p)).collect()
}

fn control_points_2d(s: &StepFile, rows: &Vec<Vec<CartesianPoint>>) -> Vec<Vec<DVec3>> {
    rows.iter()
        .map(|row| control_points_1d(s, row))
        .collect()
}

fn face_bound(s: &StepFile, b: FaceBound) -> Result<Vec<DVec3>, Error> {
    let (bound, orientation) = match &s[b] {
        Entity::FaceBound(b) => (b.bound, b.orientation),
        Entity::FaceOuterBound(b) => (b.bound, b.orientation),
        e => panic!("Could not get bound from {:?} at {:?}", e, b),
    };
    match &s[bound] {
        Entity::EdgeLoop(e) => {
            let mut d = edge_loop(s, &e.edge_list)?;
            if !orientation {
                d.reverse()
            }
            Ok(d)
        },
        Entity::VertexLoop(v) => {
            // This is an "edge loop" with a single vertex, which is
            // used for cones and not really anything else.
            Ok(vec![vertex_point(s, v.loop_vertex)])
        }
        e => panic!("{:?} is not an EdgeLoop", e),
    }
}

fn edge_loop(s: &StepFile, edge_list: &[OrientedEdge])
    -> Result<Vec<DVec3>, Error>
{
    let mut out = Vec::new();
    for (i, e) in edge_list.iter().enumerate() {
        // Remove the last item from the list, since it's the beginning
        // of the following list (hopefully)
        if i > 0 {
            out.pop();
        }
        let edge = s.entity(*e).expect("Could not get OrientedEdge");
        let o = edge_curve(s, edge.edge_element.cast(), edge.orientation)?;
        out.extend(o.into_iter());
    }
    Ok(out)
}

fn edge_curve(s: &StepFile, e: EdgeCurve, orientation: bool) -> Result<Vec<DVec3>, Error> {
    let edge_curve = s.entity(e).expect("Could not get EdgeCurve");
    let curve = curve(s, edge_curve, edge_curve.edge_geometry, orientation)?;

    let (start, end) = if orientation {
        (edge_curve.edge_start, edge_curve.edge_end)
    } else {
        (edge_curve.edge_end, edge_curve.edge_start)
    };
    let u = vertex_point(s, start);
    let v = vertex_point(s, end);
    Ok(curve.build(u, v))
}

fn curve(s: &StepFile, edge_curve: &ap214::EdgeCurve_,
         curve_id: ap214::Curve, orientation: bool) -> Result<Curve, Error>
{
    Ok(match &s[curve_id] {
        Entity::Circle(c) => {
            let (location, axis, ref_direction) = axis2_placement_3d(s, c.position.cast());
            Curve::new_circle(location, axis, ref_direction, c.radius.0.0.0,
                              edge_curve.edge_start == edge_curve.edge_end,
                              edge_curve.same_sense ^ !orientation)
        },
        Entity::Ellipse(c) => {
            let (location, axis, ref_direction) = axis2_placement_3d(s, c.position.cast());
            Curve::new_ellipse(location, axis, ref_direction,
                               c.semi_axis_1.0.0.0, c.semi_axis_2.0.0.0,
                               edge_curve.edge_start == edge_curve.edge_end,
                               edge_curve.same_sense ^ !orientation)
        },
        Entity::BSplineCurveWithKnots(c) => {
            if c.closed_curve.0 != Some(false) {
                return Err(Error::ClosedCurve);
            } else if c.self_intersect.0 != Some(false) {
                return Err(Error::SelfIntersectingCurve);
            }

            let control_points_list = control_points_1d(
                s, &c.control_points_list);

            let knots: Vec<f64> = c.knots.iter().map(|k| k.0).collect();
            let multiplicities: Vec<usize> = c.knot_multiplicities.iter()
                .map(|&k| k.try_into().expect("Got negative multiplicity"))
                .collect();
            let knot_vec = KnotVector::from_multiplicities(
                c.degree.try_into().expect("Got negative degree"),
                &knots, &multiplicities);

            let curve = nurbs::BSplineCurve::new(
                c.closed_curve.0.unwrap() == false,
                knot_vec,
                control_points_list,
            );
            Curve::BSplineCurveWithKnots(SampledCurve::new(curve))
        },
        Entity::ComplexEntity(v) if v.len() == 2 => {
            let bspline = if let Entity::BSplineCurveWithKnots(b) = &v[0] {
                b
            } else {
                warn!("Could not get BSplineCurveWithKnots from {:?}", v[0]);
                return Err(Error::UnknownCurveType)
            };
            let rational = if let Entity::RationalBSplineCurve(b) = &v[1] {
                b
            } else {
                warn!("Could not get RationalBSplineCurve from {:?}", v[1]);
                return Err(Error::UnknownCurveType)
            };
            let knots: Vec<f64> = bspline.knots.iter().map(|k| k.0).collect();
            let multiplicities: Vec<usize> = bspline.knot_multiplicities.iter()
                .map(|&k| k.try_into().expect("Got negative multiplicity"))
                .collect();
            let knot_vec = KnotVector::from_multiplicities(
                bspline.degree.try_into().expect("Got negative degree"),
                &knots, &multiplicities);

            let control_points_list = control_points_1d(
                    s, &bspline.control_points_list)
                .into_iter()
                .zip(rational.weights_data.iter())
                .map(|(p, w)| DVec4::new(p.x * w, p.y * w, p.z * w, *w))
                .collect();

            let curve = nurbs::NURBSCurve::new(
                bspline.closed_curve.0.unwrap() == false,
                knot_vec,
                control_points_list,
            );
            Curve::NURBSCurve(SampledCurve::new(curve))
        },
        Entity::SurfaceCurve(v) => {
            curve(s, edge_curve, v.curve_3d, orientation)?
        },
        Entity::SeamCurve(v) => {
            curve(s, edge_curve, v.curve_3d, orientation)?
        },
        // The Line type ignores pnt / dir and just uses u and v
        Entity::Line(_) => Curve::new_line(),
        e => {
            warn!("Could not get edge from {:?}", e);
            return Err(Error::UnknownCurveType);
        },
    })
}

fn vertex_point(s: &StepFile, v: Vertex) -> DVec3 {
    cartesian_point(s,
        s.entity(v.cast::<VertexPoint_>())
            .expect("Could not get VertexPoint")
            .vertex_geometry
            .cast())
}
