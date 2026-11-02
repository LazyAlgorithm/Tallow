# Tallow Gallery

The showcase project is installed from `Editor/templates/showcase` by the launcher's Tallow Gallery choice, or `Tallow --create PATH --showcase`. Its scene is `Scenes/Gallery.tscene`, eight areas of ordinary objects. `tools/validate_showcase.py` creates one in a path with spaces under a new name, compiles it, and with `--play` runs it with `--self-test`.

`--view N` stands the visitor somewhere worth a screenshot (0 to 11); `--fire-test N` fires N balls from there and `--cut-test N` cuts N times. `--author-scene` saves the scene again after building it from `Scripts/Gallery.bf`.

Its reflection probes are the example to copy: indoors, one to a room, the box the size of the room with Box Projection on. Probes in open places should turn Box Projection off.
