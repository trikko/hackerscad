
## Build it yourself

hackerscad is open source. On Linux or macOS, with LDC and dub, OpenCascade 7.9, GTK 4, libadwaita and GtkSourceView 5 installed:

```sh
git clone https://github.com/trikko/hackerscad
cd hackerscad
dub build -b release          # bin/hcad, the command line tool
dub build -b release :gui     # bin/hackerscad, the application
```

The first build also compiles the part that talks to OpenCascade, so it takes a few minutes. How to run the tests and make the packages for each system (the AppImage, the Windows zip, made on Linux, and the macOS app) is in [Building, in the README](https://github.com/trikko/hackerscad#building).
