/// Declarations matching shim.h. Keep in sync with that header.
module hackerscad.kernel.occt.c;

extern (C) nothrow @nogc:

struct hc_shape;

struct hc_mesh
{
    int nverts;
    float* verts;
    int ntris;
    int* tris;
    int nfaces;
    int* face_start;
}

enum HC_FUSE = 0, HC_CUT = 1, HC_COMMON = 2;
enum HC_EDGE_LINE = 0, HC_EDGE_CIRCLE = 1, HC_EDGE_OTHER = 2;

const(char)* hc_last_error();

int hc_history_size();
void hc_history_get(int* input, int* index);

void hc_shape_free(hc_shape* s);

hc_shape* hc_box(double dx, double dy, double dz);
hc_shape* hc_cylinder(double r, double h);
hc_shape* hc_cone(double r1, double r2, double h);
hc_shape* hc_sphere(double r);

hc_shape* hc_rect(double w, double h);
hc_shape* hc_circle(double r);
hc_shape* hc_polygon(const(double)* xy, int n);
hc_shape* hc_text(const(char)* utf8, double size, const(char)* font);
hc_shape* hc_profile_round(const(hc_shape)* s, double r);
hc_shape* hc_profile_offset(const(hc_shape)* s, double d);
hc_shape* hc_extrude(const(hc_shape)* s, double height, double taper_rad);
hc_shape* hc_revolve(const(hc_shape)* s, double ox, double oy, double oz, double dx, double dy, double dz, double angle_rad);

hc_shape* hc_translate(const(hc_shape)* s, double x, double y, double z);
hc_shape* hc_rotate(const(hc_shape)* s, double ax, double ay, double az, double angle_rad);
hc_shape* hc_scale(const(hc_shape)* s, double factor);
hc_shape* hc_mirror(const(hc_shape)* s, double nx, double ny, double nz);

hc_shape* hc_boolean(const(hc_shape)* a, const(hc_shape)* b, int op);
int hc_solid_count(const(hc_shape)* s);
hc_shape* hc_solid(const(hc_shape)* s, int index);

int hc_edge_count(const(hc_shape)* s);
int hc_face_count(const(hc_shape)* s);
int hc_edge_info(const(hc_shape)* s, int index, ref double[16] output);
int hc_face_info(const(hc_shape)* s, int index, ref double[7] output);

int hc_edge_faces(const(hc_shape)* s, int* output);

hc_shape* hc_fillet(const(hc_shape)* s, const(int)* edges, int nedges, double r);
hc_shape* hc_chamfer(const(hc_shape)* s, const(int)* edges, int nedges, double d);
hc_shape* hc_shell(const(hc_shape)* s, const(int)* faces, int nfaces, double thickness);
hc_shape* hc_draft(const(hc_shape)* s, const(int)* faces, int nfaces, double angle_rad,
    double px, double py, double pz, double nx, double ny, double nz);

double hc_volume(const(hc_shape)* s);
double hc_area(const(hc_shape)* s);
int hc_bbox(const(hc_shape)* s, ref double[6] output);
int hc_is_valid(const(hc_shape)* s);
double hc_distance(const(hc_shape)* a, const(hc_shape)* b, ref double[6] output);

hc_mesh* hc_tessellate(const(hc_shape)* s, double linear_deflection, double angular_deflection);
void hc_mesh_free(hc_mesh* m);

hc_shape* hc_from_mesh(const(float)* verts, int nverts, const(int)* tris, int ntris, double tolerance);
hc_shape* hc_polyline(const(double)* xyz, int n, int closed);
hc_shape* hc_spline(const(double)* xyz, int n, int closed);
hc_shape* hc_helix(double r, double pitch, double height, int left);
int hc_path_frame(const(hc_shape)* path, int at_end, ref double[6] out_);
hc_shape* hc_outline(const(double)* data, int n);
hc_shape* hc_sweep(const(hc_shape)* profile, const(hc_shape)* path, int frenet);
hc_shape* hc_loft(const(hc_shape*)* profiles, int n, int ruled);
int hc_hlr(const(hc_shape)* s, double dx, double dy, double dz, double ux, double uy, double uz, double deflection,
    double** out_);
int hc_face_loops(const(hc_shape)* s, int face, double deflection, double** out_);
void hc_free(void* p);
int hc_write_step(const(hc_shape)* s, const(char)* path);
hc_shape* hc_read_step(const(char)* path);
