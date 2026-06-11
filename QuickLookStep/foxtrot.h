#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct MeshSlice {
  const float *verts;
  const float *normals;
  /**
   * Per-vertex linear RGB color from STEP STYLED_ITEM/COLOUR_RGB entities.
   * Unstyled geometry defaults to (0.5, 0.5, 0.5) upstream.
   */
  const float *colors;
  const uint32_t *tris;
  uintptr_t vert_count;
  uintptr_t tri_count;
} MeshSlice;

bool foxtrot_load_step(const char *path, struct MeshSlice *out_mesh);

/**
 * Caller must invoke this when the mesh is no longer needed.
 */
void foxtrot_free_mesh(struct MeshSlice slice);
