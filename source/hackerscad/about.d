/// What hackerscad is, its version and what it is built with: shown by
/// `hcad --version` and the About window.
module hackerscad.about;

enum string appName = "hackerscad";
enum string appVersion = "0.3.1";
enum string appSummary = "the hacker's CAD: solid models written as code, edited with the mouse too";
enum string appWebsite = "https://github.com/trikko/hackerscad";
enum string appIssues = "https://github.com/trikko/hackerscad/issues";
enum string appAuthor = "Andrea Fontana";
enum string appCopyright = "© 2026 Andrea Fontana";
/// GPL-3.0, with an exception for models and what hackerscad makes of them
/// (MODEL-EXCEPTION.md)
enum string appLicense = "GPL-3.0-only WITH LicenseRef-hackerscad-model-exception";
enum string appModelException = "The models you write and what hackerscad makes from them (STL, 3MF, "
    ~ "STEP, images, drawings) are yours, under terms of your choice, even when they use the libraries "
    ~ "that come with hackerscad: see the hackerscad Model Exception (MODEL-EXCEPTION.md).";

/// A library hackerscad is built with, and its licence.
struct Component
{
    string name;
    string what;
    string copyright;
    string license;    /// SPDX identifier
    string url;
}

immutable Component[] components = [
    Component("Open CASCADE Technology", "exact solid modelling (B-rep), STEP, hidden lines",
        "© Open Cascade SAS", "LGPL-2.1-only WITH OCCT-exception-1.0", "https://dev.opencascade.org"),
    Component("Manifold", "fast mesh booleans", "© The Manifold Authors", "Apache-2.0",
        "https://github.com/elalish/manifold"),
    Component("Clipper2", "2D polygon clipping (in Manifold)", "© Angus Johnson", "BSL-1.0",
        "https://github.com/AngusJohnson/Clipper2"),
    Component("GTK", "the user interface", "© The GTK Team", "LGPL-2.1-or-later", "https://gtk.org"),
    Component("libadwaita", "the GNOME look", "© The GNOME Project", "LGPL-2.1-or-later",
        "https://gnome.pages.gitlab.gnome.org/libadwaita/"),
    Component("GtkSourceView", "the code editor", "© The GtkSourceView Team", "LGPL-2.1-or-later",
        "https://wiki.gnome.org/Projects/GtkSourceView"),
    Component("giD", "GTK bindings for D", "© Kymorphia, PBC", "MIT", "https://github.com/Kymorphia/gid"),
    Component("bindbc-opengl", "OpenGL bindings for D", "© Michael D. Parker", "BSL-1.0",
        "https://github.com/BindBC/bindbc-opengl"),
    Component("oneTBB", "parallel loops (in Manifold, Linux and macOS)", "© Intel Corporation", "Apache-2.0",
        "https://github.com/uxlfoundation/oneTBB"),
    Component("Mesa", "software OpenGL where the machine has none (Windows package)", "© The Mesa authors", "MIT",
        "https://mesa3d.org"),
    Component("Visual C++ runtime", "vcruntime140.dll (Windows package)", "© Microsoft Corporation",
        "LicenseRef-Microsoft-VC-Redistributable", "https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files"),
];

/// One line per component, for `hcad --version`.
string componentList()
{
    import std.format : format;
    string s;
    foreach (c; components)
        s ~= format("  %-24s %-40s %s\n", c.name, c.license, c.url);
    return s;
}
