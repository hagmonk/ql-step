#ifndef OCCT_BRIDGE_H
#define OCCT_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Field layout mirrors foxtrot's MeshSlice so the Swift side treats both
 * backends identically. Colors are sRGB-encoded floats per vertex. */
typedef struct OcctMesh {
  const float *verts;
  const float *normals;
  const float *colors;
  const uint32_t *tris;
  size_t vert_count;
  size_t tri_count;
} OcctMesh;

typedef struct OcctLoadOptions {
  double linear_deflection;
  double angular_deflection;
  bool relative_deflection;
  bool parallel_meshing;
} OcctLoadOptions;

OcctLoadOptions occt_default_load_options(void);

/* Loads a STEP file with OpenCascade (STEPCAFControl/XCAF — the same engine
 * f3d uses), tessellates it, and returns flat buffers. Returns false on any
 * parse/transfer failure. */
bool occt_load_step(const char *path, OcctMesh *out_mesh);
bool occt_load_step_with_options(const char *path, const OcctLoadOptions *options,
                                 OcctMesh *out_mesh);

/* Loads STEP bytes from memory with OpenCascade. The name is only used as an
 * auxiliary stream name for diagnostics and may be NULL. */
bool occt_load_step_data(const void *bytes, size_t length, const char *name,
                         OcctMesh *out_mesh);
bool occt_load_step_data_with_options(const void *bytes, size_t length,
                                      const char *name,
                                      const OcctLoadOptions *options,
                                      OcctMesh *out_mesh);

/* Caller must invoke this when the mesh is no longer needed. */
void occt_free_mesh(OcctMesh mesh);

/* Buffer-level frees for callers that transfer individual mesh buffers to
 * owning containers such as Swift Data(bytesNoCopy:deallocator:). */
void occt_free_float_buffer(const float *buffer);
void occt_free_uint32_buffer(const uint32_t *buffer);

#ifdef __cplusplus
}
#endif

#endif /* OCCT_BRIDGE_H */
