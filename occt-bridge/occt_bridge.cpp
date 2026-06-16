// STEP -> triangle mesh via OpenCascade, mirroring f3d's vtkF3DOCCTReader:
// STEPCAFControl_Reader with color mode, XCAFPrs::CollectStyleSettings for
// styles passed down to faces, BRepMesh_IncrementalMesh for tessellation,
// per-face Poly_Triangulation with location baked into points.

#include "occt_bridge.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <istream>
#include <streambuf>
#include <string>
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
static constexpr bool kParallelMeshing = true;
static constexpr float kF3DGrey = 84.0f / 255.0f;

using Clock = std::chrono::steady_clock;

static double elapsedMs(Clock::time_point start, Clock::time_point end) {
  return std::chrono::duration<double, std::milli>(end - start).count();
}

static bool profileEnabled() { return std::getenv("QLSTEP_PROFILE") != nullptr; }

extern "C" OcctLoadOptions occt_default_load_options(void) {
  return {kLinearDeflection, kAngularDeflection, kRelativeDeflection,
          kParallelMeshing};
}

static OcctLoadOptions normalizedOptions(const OcctLoadOptions *options) {
  OcctLoadOptions normalized =
      options != nullptr ? *options : occt_default_load_options();
  if (normalized.linear_deflection <= 0) {
    normalized.linear_deflection = kLinearDeflection;
  }
  if (normalized.angular_deflection <= 0) {
    normalized.angular_deflection = kAngularDeflection;
  }
  return normalized;
}

struct MeshCounts {
  size_t vertices = 0;
  size_t triangles = 0;
};

class MemoryBuffer : public std::streambuf {
public:
  MemoryBuffer(const void *bytes, size_t length) {
    char *begin = const_cast<char *>(static_cast<const char *>(bytes));
    setg(begin, begin, begin + length);
  }
};

// Fill unset style properties from a parent style (f3d PassDownStyleProps)
static void passDownStyle(const XCAFPrs_Style &parent, XCAFPrs_Style &child) {
  if (!child.IsSetColorSurf() && parent.IsSetColorSurf()) {
    child.SetColorSurf(parent.GetColorSurfRGBA());
  }
}

static void configureReader(STEPCAFControl_Reader &reader) {
  reader.SetColorMode(true);
  reader.SetNameMode(false);
  reader.SetLayerMode(false);
}

static MeshCounts countTriangulation(const TopoDS_Shape &shape) {
  MeshCounts counts;
  for (TopExp_Explorer exFace(shape, TopAbs_FACE); exFace.More();
       exFace.Next()) {
    TopLoc_Location location;
    const Handle(Poly_Triangulation) poly =
        BRep_Tool::Triangulation(TopoDS::Face(exFace.Current()), location);
    if (poly.IsNull()) {
      continue;
    }
    counts.vertices += static_cast<size_t>(poly->NbNodes());
    counts.triangles += static_cast<size_t>(poly->NbTriangles());
  }
  return counts;
}

static bool transferStep(STEPCAFControl_Reader &reader,
                         const OcctLoadOptions &options, OcctMesh *out) {
  const bool profile = profileEnabled();
  const auto transferStart = Clock::now();
  Handle(TDocStd_Document) doc;
  XCAFApp_Application::GetApplication()->NewDocument("BinXCAF", doc);
  if (!reader.Transfer(doc)) {
    return false;
  }
  const auto transferEnd = Clock::now();

  Handle(XCAFDoc_ShapeTool) shapeTool =
      XCAFDoc_DocumentTool::ShapeTool(doc->Main());
  TDF_LabelSequence freeLabels;
  shapeTool->GetFreeShapes(freeLabels);

  std::vector<float> verts;
  std::vector<float> normals;
  std::vector<float> colors;
  std::vector<uint32_t> tris;
  uint32_t shift = 0;

  double styleMs = 0;
  double meshMs = 0;
  double countMs = 0;
  double emitMs = 0;
  size_t faceCount = 0;
  size_t normalComputeCount = 0;
  size_t normalReuseCount = 0;

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
    const auto styleStart = Clock::now();
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
    styleMs += elapsedMs(styleStart, Clock::now());

    const auto meshStart = Clock::now();
    BRepMesh_IncrementalMesh(shape, options.linear_deflection,
                             options.relative_deflection,
                             options.angular_deflection,
                             options.parallel_meshing);
    meshMs += elapsedMs(meshStart, Clock::now());

    const auto countStart = Clock::now();
    const MeshCounts shapeCounts = countTriangulation(shape);
    verts.reserve(verts.size() + shapeCounts.vertices * 3);
    normals.reserve(normals.size() + shapeCounts.vertices * 3);
    colors.reserve(colors.size() + shapeCounts.vertices * 3);
    tris.reserve(tris.size() + shapeCounts.triangles * 3);
    countMs += elapsedMs(countStart, Clock::now());

    const auto emitStart = Clock::now();
    for (TopExp_Explorer exFace(shape, TopAbs_FACE); exFace.More();
         exFace.Next()) {
      TopoDS_Face face = TopoDS::Face(exFace.Current());
      TopLoc_Location location;
      Handle(Poly_Triangulation) poly =
          BRep_Tool::Triangulation(face, location);
      if (poly.IsNull()) {
        continue;
      }
      if (poly->HasNormals()) {
        normalReuseCount++;
      } else {
        Poly::ComputeNormals(poly);
        normalComputeCount++;
      }
      faceCount++;
      const bool reversed = (face.Orientation() == TopAbs_REVERSED);
      const gp_Trsf trsf = location.Transformation();
      const bool hasTransform = trsf.Form() != gp_Identity;

      float rgb[3] = {kF3DGrey, kF3DGrey, kF3DGrey};
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
      for (int i = 1; i <= nbV; i++) {
        const gp_Pnt p =
            hasTransform ? poly->Node(i).Transformed(trsf) : poly->Node(i);
        verts.push_back(static_cast<float>(p.X()));
        verts.push_back(static_cast<float>(p.Y()));
        verts.push_back(static_cast<float>(p.Z()));

        gp_Dir n = poly->HasNormals() ? gp_Dir(poly->Normal(i))
                                      : gp_Dir(0, 0, 1);
        if (hasTransform) {
          n.Transform(trsf);
        }
        const float flip = reversed ? -1.0f : 1.0f;
        normals.push_back(static_cast<float>(n.X() * flip));
        normals.push_back(static_cast<float>(n.Y() * flip));
        normals.push_back(static_cast<float>(n.Z() * flip));

        colors.push_back(rgb[0]);
        colors.push_back(rgb[1]);
        colors.push_back(rgb[2]);
      }

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
    emitMs += elapsedMs(emitStart, Clock::now());
  }

  if (verts.empty() || tris.empty()) {
    return false;
  }

  const auto copyStart = Clock::now();
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

  if (profile) {
    const auto done = Clock::now();
    std::fprintf(stderr,
                 "occt profile: transfer %.1f ms, styles %.1f, mesh %.1f, "
                 "count %.1f, emit %.1f, copy %.1f, total %.1f | faces %zu, "
                 "verts %zu, tris %zu, normals reused/computed %zu/%zu\n",
                 elapsedMs(transferStart, transferEnd), styleMs, meshMs,
                 countMs, emitMs, elapsedMs(copyStart, done),
                 elapsedMs(transferStart, done), faceCount, out->vert_count,
                 out->tri_count, normalReuseCount, normalComputeCount);
  }
  return true;
}

static bool loadStep(const char *path, const OcctLoadOptions *options,
                     OcctMesh *out) {
  if (path == nullptr || out == nullptr) {
    return false;
  }

  STEPCAFControl_Reader reader;
  configureReader(reader);
  if (reader.ReadFile(path) != IFSelect_RetDone) {
    return false;
  }

  return transferStep(reader, normalizedOptions(options), out);
}

static bool loadStepData(const void *bytes, size_t length, const char *name,
                         const OcctLoadOptions *options, OcctMesh *out) {
  if (bytes == nullptr || length == 0 || out == nullptr) {
    return false;
  }

  STEPCAFControl_Reader reader;
  configureReader(reader);

  MemoryBuffer buffer(bytes, length);
  std::istream stream(&buffer);
  const char *streamName = name != nullptr ? name : "memory.step";
  if (reader.ReadStream(streamName, stream) != IFSelect_RetDone) {
    return false;
  }

  return transferStep(reader, normalizedOptions(options), out);
}

extern "C" bool occt_load_step(const char *path, OcctMesh *out) {
  return occt_load_step_with_options(path, nullptr, out);
}

extern "C" bool occt_load_step_with_options(const char *path,
                                            const OcctLoadOptions *options,
                                            OcctMesh *out) {
  try {
    return loadStep(path, options, out);
  } catch (const Standard_Failure &) {
    return false;
  } catch (...) {
    return false;
  }
}

extern "C" bool occt_load_step_data(const void *bytes, size_t length,
                                    const char *name, OcctMesh *out) {
  return occt_load_step_data_with_options(bytes, length, name, nullptr, out);
}

extern "C" bool occt_load_step_data_with_options(const void *bytes,
                                                 size_t length,
                                                 const char *name,
                                                 const OcctLoadOptions *options,
                                                 OcctMesh *out) {
  try {
    return loadStepData(bytes, length, name, options, out);
  } catch (const Standard_Failure &) {
    return false;
  } catch (...) {
    return false;
  }
}

extern "C" void occt_free_mesh(OcctMesh mesh) {
  occt_free_float_buffer(mesh.verts);
  occt_free_float_buffer(mesh.normals);
  occt_free_float_buffer(mesh.colors);
  occt_free_uint32_buffer(mesh.tris);
}

extern "C" void occt_free_float_buffer(const float *buffer) {
  delete[] buffer;
}

extern "C" void occt_free_uint32_buffer(const uint32_t *buffer) {
  delete[] buffer;
}
