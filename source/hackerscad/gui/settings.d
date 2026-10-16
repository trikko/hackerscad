/// The window's preferences, kept between runs in a small JSON file:
/// ~/.config/hackerscad/settings.json (or $XDG_CONFIG_HOME/hackerscad) on
/// Linux, ~/Library/Application Support/hackerscad on macOS,
/// %APPDATA%\hackerscad on Windows.
module hackerscad.gui.settings;

import std.file : mkdirRecurse, readText, write;
import djson;
import std.path : buildPath, dirName;
import std.process : environment;

/// The file the preferences are kept in.
string settingsFile()
{
    version (Windows)
        immutable dir = buildPath(environment.get("APPDATA", ""), "hackerscad");
    else version (OSX)
        immutable dir = buildPath(environment.get("HOME", ""), "Library", "Application Support", "hackerscad");
    else
    {
        immutable config = environment.get("XDG_CONFIG_HOME", "");
        immutable dir = config.length ? buildPath(config, "hackerscad")
            : buildPath(environment.get("HOME", ""), ".config", "hackerscad");
    }
    return buildPath(dir, "settings.json");
}

/// The preference `key`, or `fallback` when it is not set (or the file
/// cannot be read).
string setting(string key, string fallback)
{
    try
    {
        auto j = parseJSONComplete(readText(settingsFile()));
        if (auto v = j.getPtr(key))
            if (v.isString)
                return v.get!string;
    }
    catch (Exception)
    {
    }
    return fallback;
}

/// Sets the preference `key`, keeping the others; a file that cannot be
/// written leaves the preference for this run only.
void setSetting(string key, string value)
{
    JValue j = JSOB();
    try
        j = parseJSONComplete(readText(settingsFile()));
    catch (Exception)
    {
    }
    if (!j.isObject)
        j = JSOB();
    j[key] = value;
    try
    {
        mkdirRecurse(dirName(settingsFile()));
        write(settingsFile(), j.toJSON(true) ~ "\n");
    }
    catch (Exception)
    {
    }
}
