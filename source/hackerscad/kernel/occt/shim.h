/* C interface to OpenCascade used by hackerscad.
 * Every function returning a pointer returns NULL on failure; the reason is
 * available from hc_last_error(). Shapes are immutable: operations always
 * return a new shape that must be released with hc_shape_free(). */
#ifndef HACKERSCAD_OCCT_SHIM_H
#define HACKERSCAD_OCCT_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hc_shape hc_shape;

typedef struct hc_mesh {
    int nverts;     /* vertices: 3 floats each */
    float *verts;
    int ntris;      /* triangles: 3 indices each */
    int *tris;
    int nfaces;     /* face i owns triangles face_start[i] .. face_start[i+1] */
    int *face_start;
} hc_mesh;

enum { HC_FUSE = 0, HC_CUT = 1, HC_COMMON = 2 };
enum { HC_EDGE_LINE = 0, HC_EDGE_CIRCLE = 1, HC_EDGE_OTHER = 2 };

const char *hc_last_error(void);

/* Workarounds for bugs of OpenCascade (WORKAROUND in shim.cpp), all on at
 * start. A test turns one off to see whether the bug is still there. */
enum { HC_WORKAROUND_MESH_DIVIDE = 0, HC_WORKAROUND_SHELL_STRATEGIES = 1, HC_WORKAROUND_HELIX_PIECES = 2,
    HC_WORKAROUND_MESH_VOLUME = 3, HC_WORKAROUND_OFFSET_TOLERANCE = 4,
    HC_WORKAROUND_FILL_CHORDS = 5 };
void hc_workaround(int which, int on);
void hc_set_threads(int n);

/* Face history of the last operation on this thread: for every face of the
 * result, the operand it comes from (0 = first, 1 = second) and its face
 * index there, or -1/-1 for faces created by the operation itself. */
int hc_history_size(void);
void hc_history_get(int *input, int *index);

void hc_shape_free(hc_shape *s);

/* Primitives. Box has its min corner at the origin; cylinder and cone sit on
 * the XY plane with their axis along +Z; sphere is centred at the origin. */
hc_shape *hc_box(double dx, double dy, double dz);
hc_shape *hc_cylinder(double r, double h);
hc_shape *hc_cone(double r1, double r2, double h);
hc_shape *hc_sphere(double r);
hc_shape *hc_torus(double major, double minor);

/* Profiles: planar faces on the XY plane (a compound when there are several).
 * Rectangle and circle are centred on the origin; polygon takes n points
 * as x0 y0 x1 y1 …; text starts at the origin on its baseline (`font` is a
 * family name or a font file path). */
hc_shape *hc_rect(double w, double h);
hc_shape *hc_circle(double r);
hc_shape *hc_ellipse(double rx, double ry);
hc_shape *hc_polygon(const double *xy, int n);
hc_shape *hc_text(const char *utf8, double size, const char *font);
/* Rounds every corner of the profile; corners that cannot be rounded stay. */
hc_shape *hc_profile_round(const hc_shape *s, double r);
/* Grows (d > 0) or shrinks (d < 0) the profile, with rounded outer corners. */
hc_shape *hc_profile_offset(const hc_shape *s, double d);
/* Profile → solid along +Z (−Z for negative height); taper tilts the sides
 * (positive narrows towards the top). */
hc_shape *hc_extrude(const hc_shape *s, double height, double taper_rad);
/* Profile → solid of revolution around an axis in the profile's plane. */
hc_shape *hc_revolve(const hc_shape *s, double ox, double oy, double oz, double dx, double dy, double dz, double angle_rad);

/* Transformations. Rotation is around an axis through the origin. */
hc_shape *hc_translate(const hc_shape *s, double x, double y, double z);
hc_shape *hc_rotate(const hc_shape *s, double ax, double ay, double az, double angle_rad);
hc_shape *hc_scale(const hc_shape *s, double factor);
hc_shape *hc_scale_xyz(const hc_shape *s, double sx, double sy, double sz);
hc_shape *hc_mirror(const hc_shape *s, double nx, double ny, double nz);

hc_shape *hc_boolean(const hc_shape *a, const hc_shape *b, int op);
hc_shape *hc_boolean_merged(const hc_shape *a, const hc_shape *b, int op);
hc_shape *hc_fuse_all(const hc_shape *const *shapes, int n);
hc_shape *hc_cut_all(const hc_shape *a, const hc_shape *const *tools, int n);
hc_shape *hc_tiles(const hc_shape *const *motifs, int nm, const double *place, int n, const hc_shape *region, int mode, double minArea);
hc_shape *hc_wrap_tool(const hc_shape *s, int face, const hc_shape *profile, int project, const double *at, const double *dir, double inner, double outer);
hc_shape *hc_wrap_direct(const hc_shape *s, int face, const hc_shape *profile, int project, const double *at, const double *dir, double floor);
int hc_spots(const hc_shape *s, int n, double margin, double *out);
int hc_wrap_skipped(void);
hc_shape *hc_wrap_flat(const hc_shape *s, int face, const double *at, double *round_, double *middle);
int hc_wrap_outside(const hc_shape *s, int face, const hc_shape *profile, int project, const double *at, const double *dir, double floor, int *out, int max, int *regions);
hc_shape *hc_profile_regions(const hc_shape *profile, const int *which, int n);
hc_shape *hc_offset_solid(const hc_shape *s, double d, int sharp);
int hc_touching_count(const hc_shape *s);
hc_shape *hc_bridge_touching(const hc_shape *s, double r);
int hc_mass_props(const hc_shape *s, double out[7]);
hc_shape *hc_section(const hc_shape *s, const double origin[3], const double normal[3]);

/* Disconnected solid bodies of a shape (e.g. after a cut in two). The
 * history of hc_solid maps the body's faces to the faces of `s`. */
int hc_solid_count(const hc_shape *s);
hc_shape *hc_solid(const hc_shape *s, int index);

/* Topology: edges and faces are indexed from 0 in a stable order for a given
 * shape; selectors live on the D side and use these queries. */
int hc_edge_count(const hc_shape *s);
int hc_face_count(const hc_shape *s);
/* out: start xyz, end xyz, mid xyz, then for circles centre xyz, axis xyz
 * and radius; returns HC_EDGE_* or -1 */
int hc_edge_info(const hc_shape *s, int index, double out[23]);
int hc_face_outer_edges(const hc_shape *s, int face, int *out, int max);
int hc_profile_part_count(const hc_shape *s, int which);
hc_shape *hc_profile_part(const hc_shape *s, int which, int index);
/* out: centre of mass xyz, normal at centre xyz, area */
int hc_face_info(const hc_shape *s, int index, double out[7]);

/* For every edge, the indices of its two faces (-1 when missing): out has
 * 2 * edge count entries. Returns the edge count, or -1. */
int hc_edge_faces(const hc_shape *s, int *out);

hc_shape *hc_fillet(const hc_shape *s, const int *edges, int nedges, double r);
hc_shape *hc_chamfer(const hc_shape *s, const int *edges, int nedges, double d);
int hc_point_inside(const hc_shape *s, double x, double y, double z);
int hc_face_cylinder(const hc_shape *s, int index, double out[11]);
hc_shape *hc_face_prism(const hc_shape *s, int face, double vx, double vy, double vz);
hc_shape *hc_shell(const hc_shape *s, const int *faces, int nfaces, double thickness);
/* Tilts faces by `angle` around their intersection with the neutral plane
 * (point + normal); `pull` is the mould opening direction. */
hc_shape *hc_draft(const hc_shape *s, const int *faces, int nfaces, double angle_rad,
                   double px, double py, double pz, double nx, double ny, double nz);

/* Measurements. bbox out: xmin ymin zmin xmax ymax zmax */
double hc_volume(const hc_shape *s);
double hc_area(const hc_shape *s);
int hc_bbox(const hc_shape *s, double out[6]);
int hc_is_valid(const hc_shape *s);
/* Minimum distance between two shapes; out: closest point on a, on b. */
double hc_distance(const hc_shape *a, const hc_shape *b, double out[6]);

hc_mesh *hc_tessellate(const hc_shape *s, double linear_deflection, double angular_deflection);
void hc_mesh_free(hc_mesh *m);

/* A closed triangle mesh (3 floats per vertex, 3 indices per triangle) as a
 * solid: triangles are sewn together and coplanar neighbours merged. */
hc_shape *hc_from_mesh(const float *verts, int nverts, const int *tris, int ntris, double tolerance);

/* Paths (wires) for sweeps. The helix winds around +Z from (r, 0, 0). */
hc_shape *hc_polyline(const double *xyz, int n, int closed);
hc_shape *hc_spline(const double *xyz, int n, int closed);
hc_shape *hc_helix(double r, double pitch, double height, int left);
hc_shape *hc_helix_tapered(double r, double pitch, double height, int left, double taper);
/* a right-handed ISO metric thread on z = 0 .. length, built from its boundary; ends chamfered by `chamfer` */
hc_shape *hc_iso_thread(double d, double pitch, double length, double chamfer);
/* a right-handed thread band from its profile's corners (r z each, over one lead), z about -2 leads .. length + 2 leads */
hc_shape *hc_thread_band(const double *rz, int n, double lead, double length, double slope);
/* Start (at_end = 0) or end point and tangent of a path; out: xyz, txyz. */
int hc_path_frame(const hc_shape *path, int at_end, double out[6]);

/* A planar profile from segments of 7 doubles: kind (0 line a→b, 1 arc a→b
 * through m, 2 end of loop, 3 a whole ellipse around a with radii bx along
 * its x axis, mx radians from X, and by), ax ay bx by mx my. Nested loops are
 * holes. */
hc_shape *hc_outline(const double *data, int n);
/* one open or closed chain of outline records as a path on XY */
hc_shape *hc_outline_path(const double *data, int n);
/* a path in space: records of 10 doubles, kind (0 line a→b, 1 arc a→b through m), a, b, m */
hc_shape *hc_wire3(const double *data, int n);
/* edges of a shape (indices as hc_edge_info's) joined into one path */
hc_shape *hc_edges_path(const hc_shape *s, const int *idx, int n);
/* the curve that flat paths a and b both look like across their planes (normals, or zero to find them) */
hc_shape *hc_projected_curve(const hc_shape *a, const hc_shape *b, const double na[3], const double nb[3]);
/* an oblique prism: the profile pushed along (dx, dy, height) */
hc_shape *hc_extrude_shear(const hc_shape *s, double height, double dx, double dy);
/* every area an outline's loops make: the full ones first (*full_count of them), then the empty */
hc_shape *hc_outline_regions(const double *data, int n, int *full_count);

/* Sweeps a profile (drawn on XY around the origin) along a path; the profile
 * starts normal to the path, its +Y as close to world +Z as possible.
 * frenet = 1 follows the path's curvature (helices). */
hc_shape *hc_sweep(const hc_shape *profile, const hc_shape *path, int frenet);
hc_shape *hc_sweep_twisted(const hc_shape *profile, const hc_shape *path, int frenet, double twist);
/* the same, the roll decided by frenet, n angles evenly along the path, a fixed up (zero: none) or a guide (null: none) */
hc_shape *hc_sweep_ex(const hc_shape *profile, const hc_shape *path, int frenet, const double *angles, int n,
                      const double up[3], const hc_shape *guide);
/* Surfaces: through paths in order; the pieces of a solid cut by a surface; a
 * surface made t thick; surfaces sewn into a closed solid. */
hc_shape *hc_loft_open(const hc_shape *const *paths, int n, int ruled);
hc_shape *hc_join_touching(const hc_shape *a, const hc_shape *b, int glue);
hc_shape *hc_thread_direct(const double *rz, int n, double lead, double length, double chamfer, double rOut);
hc_shape *hc_thread_sleeve(const double *rz, int n, double lead, double length, int sides, double rPoly);
hc_shape *hc_join_coincident(const hc_shape *a, const hc_shape *b);
hc_shape *hc_fill(const hc_shape *path, const hc_shape *s, const int *idx, int n, const int *tangent, int nt,
                  const double *xyz, int np);
hc_shape *hc_thicken_loft(const hc_shape *const *paths, int n, int ruled, double t);
hc_shape *hc_split_by(const hc_shape *s, const hc_shape *tool);
hc_shape *hc_thicken(const hc_shape *s, double t);
/* the point of s nearest to p and its face's normal there: x y z nx ny nz; 0 off its faces */
int hc_normal_at(const hc_shape *s, const double p[3], double out[6]);
hc_shape *hc_sew(const hc_shape *const *parts, int n, double tolerance, int *free_edges);
/* A solid through profiles already placed in space (ruled: flat sides). */
hc_shape *hc_loft(const hc_shape *const *profiles, int n, int ruled);

/* Drawings. hc_hlr projects the shape along dir (from the model towards the
 * viewer) with up as the vertical: out gets segments x1 y1 x2 y2 kind (0
 * visible edge, 1 visible tangent edge, 2 visible silhouette, 3 hidden) in
 * view coordinates. hc_face_loops gives the boundary loops of a face as
 * 3D polylines: for each loop the point count, then x y z per point.
 * Both return a count (-1 on failure); free the buffer with hc_free. */
int hc_hlr(const hc_shape *s, double dx, double dy, double dz, double ux, double uy, double uz, double deflection,
           double **out);
int hc_face_loops(const hc_shape *s, int face, double deflection, double **out);
void hc_free(void *p);

/* one product per shape, named; n >= 1 */
int hc_write_step(const hc_shape *const *shapes, const char *const *names, int n, const char *path);
hc_shape *hc_read_step(const char *path);

#ifdef __cplusplus
}
#endif

#endif
