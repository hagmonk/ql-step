// STEP -> triangle mesh via OpenCascade, mirroring f3d's vtkF3DOCCTReader:
// STEPCAFControl_Reader with color mode, XCAFPrs::CollectStyleSettings for
// styles passed down to faces, BRepMesh_IncrementalMesh for tessellation,
// per-face Poly_Triangulation with location baked into points.

#include "occt_bridge.h"

#include <algorithm>
#include <utility>
#include <vector>

#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Poly.hxx>
#include <Poly_Triangulation.hxx>
#include <Quantity_Color.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <Standard_Failure.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDocStd_Document.hxx>
#include <TopAbs_Orientation.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <XCAFPrs.hxx>
#include <XCAFPrs_IndexedDataMapOfShapeStyle.hxx>
#include <XCAFPrs_Style.hxx>
#include <gp_Dir.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>

// f3d defaults (vtkF3DOCCTReader.h)
static constexpr double kLinearDeflection = 0.1;
static constexpr double kAngularDeflection = 0.5;
static constexpr bool kRelativeDeflection = false;

// Fill unset style properties from a parent style (f3d PassDownStyleProps)
static void passDownStyle(const XCAFPrs_Style &parent, XCAFPrs_Style &child) {
  if (!child.IsSetColorSurf() && parent.IsSetColorSurf()) {
    child.SetColorSurf(parent.GetColorSurfRGBA());
  }
}

static bool loadStep(const char *path, OcctMesh *out) {
  STEPCAFControl_Reader reader;
  reader.SetColorMode(true);
  reader.SetNameMode(false);
  reader.SetLayerMode(false);
  if (reader.ReadFile(path) != IFSelect_RetDone) {
    return false;
  }

  Handle(TDocStd_Document) doc;
  XCAFApp_Application::GetApplication()->NewDocument("BinXCAF", doc);
  if (!reader.Transfer(doc)) {
    return false;
  }

  Handle(XCAFDoc_ShapeTool) shapeTool =
      XCAFDoc_DocumentTool::ShapeTool(doc->Main());
  TDF_LabelSequence freeLabels;
  shapeTool->GetFreeShapes(freeLabels);

  std::vector<float> verts;
  std::vector<float> normals;
  std::vector<float> colors;
  std::vector<uint32_t> tris;
  uint32_t shift = 0;

  for (Standard_Integer li = 1; li <= freeLabels.Length(); li++) {
    const TDF_Label label = freeLabels.Value(li);
    // GetShape on an assembly label yields a compound with every child
    // instance located, so face locations below carry the full transform
    TopoDS_Shape shape = shapeTool->GetShape(label);
    if (shape.IsNull()) {
      continue;
    }

    // Collect document styles and pass them down to faces, deepest shape
    // type first so a face-level style overrides its solid's (f3d
    // CollectInheritedStyles)
    XCAFPrs_IndexedDataMapOfShapeStyle collected;
    XCAFPrs::CollectStyleSettings(label, TopLoc_Location(), collected);
    std::vector<std::pair<TopoDS_Shape, XCAFPrs_Style>> styled;
    for (XCAFPrs_IndexedDataMapOfShapeStyle::Iterator it(collected);
         it.More(); it.Next()) {
      if (it.Key().ShapeType() <= TopAbs_FACE) {
        styled.emplace_back(it.Key(), it.Value());
      }
    }
    std::stable_sort(styled.begin(), styled.end(),
                     [](const auto &a, const auto &b) {
                       return a.first.ShapeType() > b.first.ShapeType();
                     });
    XCAFPrs_IndexedDataMapOfShapeStyle faceStyles;
    for (const auto &[styledShape, style] : styled) {
      for (TopExp_Explorer it(styledShape, TopAbs_FACE); it.More();
           it.Next()) {
        if (faceStyles.Contains(it.Current())) {
          passDownStyle(style, faceStyles.ChangeFromKey(it.Current()));
        } else {
          faceStyles.Add(it.Current(), style);
        }
      }
    }

    BRepMesh_IncrementalMesh(shape, kLinearDeflection, kRelativeDeflection,
                             kAngularDeflection, true);

    for (TopExp_Explorer exFace(shape, TopAbs_FACE); exFace.More();
         exFace.Next()) {
      TopoDS_Face face = TopoDS::Face(exFace.Current());
      TopLoc_Location location;
      Handle(Poly_Triangulation) poly =
          BRep_Tool::Triangulation(face, location);
      if (poly.IsNull()) {
        continue;
      }
      Poly::ComputeNormals(poly);
      const bool reversed = (face.Orientation() == TopAbs_REVERSED);
      const gp_Trsf trsf = location.Transformation();

      float rgb[3] = {1.0f, 1.0f, 1.0f};
      if (faceStyles.Contains(face)) {
        const XCAFPrs_Style &style = faceStyles.FindFromKey(face);
        if (style.IsSetColorSurf()) {
          Standard_Real r, g, b;
          style.GetColorSurf().Values(r, g, b, Quantity_TOC_sRGB);
          rgb[0] = static_cast<float>(r);
          rgb[1] = static_cast<float>(g);
          rgb[2] = static_cast<float>(b);
        }
      }

      const int nbV = poly->NbNodes();
      const int nbT = poly->NbTriangles();
      verts.reserve(verts.size() + nbV * 3);
      normals.reserve(normals.size() + nbV * 3);
      colors.reserve(colors.size() + nbV * 3);
      for (int i = 1; i <= nbV; i++) {
        const gp_Pnt p = poly->Node(i).Transformed(trsf);
        verts.push_back(static_cast<float>(p.X()));
        verts.push_back(static_cast<float>(p.Y()));
        verts.push_back(static_cast<float>(p.Z()));

        gp_Dir n = poly->HasNormals() ? gp_Dir(poly->Normal(i))
                                      : gp_Dir(0, 0, 1);
        n.Transform(trsf);
        const double flip = reversed ? -1.0 : 1.0;
        normals.push_back(static_cast<float>(n.X() * flip));
        normals.push_back(static_cast<float>(n.Y() * flip));
        normals.push_back(static_cast<float>(n.Z() * flip));

        colors.push_back(rgb[0]);
        colors.push_back(rgb[1]);
        colors.push_back(rgb[2]);
      }

      tris.reserve(tris.size() + nbT * 3);
      for (int i = 1; i <= nbT; i++) {
        int n1, n2, n3;
        poly->Triangle(i).Get(n1, n2, n3);
        if (reversed) {
          std::swap(n1, n3);
        }
        tris.push_back(shift + static_cast<uint32_t>(n1) - 1);
        tris.push_back(shift + static_cast<uint32_t>(n2) - 1);
        tris.push_back(shift + static_cast<uint32_t>(n3) - 1);
      }

      shift += static_cast<uint32_t>(nbV);
    }
  }

  if (verts.empty() || tris.empty()) {
    return false;
  }

  auto release = [](std::vector<float> &v) -> float * {
    float *buf = new float[v.size()];
    std::copy(v.begin(), v.end(), buf);
    return buf;
  };
  out->vert_count = verts.size() / 3;
  out->tri_count = tris.size() / 3;
  out->verts = release(verts);
  out->normals = release(normals);
  out->colors = release(colors);
  uint32_t *ibuf = new uint32_t[tris.size()];
  std::copy(tris.begin(), tris.end(), ibuf);
  out->tris = ibuf;
  return true;
}

extern "C" bool occt_load_step(const char *path, OcctMesh *out) {
  try {
    return loadStep(path, out);
  } catch (const Standard_Failure &) {
    return false;
  } catch (...) {
    return false;
  }
}

extern "C" void occt_free_mesh(OcctMesh mesh) {
  delete[] mesh.verts;
  delete[] mesh.normals;
  delete[] mesh.colors;
  delete[] mesh.tris;
}
