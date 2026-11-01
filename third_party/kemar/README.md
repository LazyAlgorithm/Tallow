# KEMAR HRTF measurements

`compact.zip` is the "compact" set of head-related impulse responses measured on a KEMAR dummy head
microphone at the MIT Media Lab by Bill Gardner and Keith Martin (1994), from
https://sound.media.mit.edu/resources/KEMAR.html

The data is copyright 1994 MIT Media Laboratory and is provided free with no restrictions on use,
provided the authors are cited when it is used in any research or commercial application:

> Gardner, W. G., and Martin, K. D. (1995). HRTF measurements of a KEMAR. Journal of the
> Acoustical Society of America, 97(6), 3907-3908.

Tallow's HRTF audio is built from this data: `tools/make_hrtf.py` turns it into
`native/tallow_hrtf_data.h`, which is compiled into the engine.
