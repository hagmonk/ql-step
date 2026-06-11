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

/* Loads a STEP file with OpenCascade (STEPCAFControl/XCAF — the same engine
 * f3d uses), tessellates it, and returns flat buffers. Returns false on any
 * parse/transfer failure. */
bool occt_load_step(const char *path, OcctMesh *out_mesh);

/* Caller must invoke this when the mesh is no longer needed. */
void occt_free_mesh(OcctMesh mesh);

#ifdef __cplusplus
}
#endif

#endif /* OCCT_BRIDGE_H */
