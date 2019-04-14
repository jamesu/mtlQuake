# Overview
mtlQuake is a Quake 1 port using Metal instead of OpenGL for rendering. It is based on the popular [QuakeSpasm](http://quakespasm.sourceforge.net/) and [vkQuake](https://github.com/Novum/vkQuake) ports and runs all mods compatible with it like [Arcane Dimensions](https://www.quaddicted.com/reviews/ad_v1_50final.html) or [In The Shadows](http://www.moddb.com/mods/its).

Compared to QuakeSpasm mtlQuake also features a software Quake like underwater effect, has better color precision, generates mipmap for water surfaces at runtime and has native support for anti-aliasing and AF.

mtlQuake also serves as a Metal demo application that shows basic usage of the API. For example it demonstrates mixed render passes, buffer management, and compute pipeline usage.

# Building

## Mac

Prerequisites:

* [XCode](https://developer.apple.com/xcode/)

### XCode

Install [XCode](https://developer.apple.com/xcode/) and open up the `mtlQuake.xcodeproj`. The project should build out of the box.

### Note

For convenience, mtlQuake includes a prebuilt copy of SDL 2.0.9. You may download the sourcecode from `https://libsdl.org/release/SDL2-2.0.9.zip` if you wish to rebuild it.

mtlQuake requires at least **SDL2 2.0.9 with enabled Metal support**.

# Usage

Quake has 4 episodes that are split into 2 files:

* `pak0.pak`: contains episode 1
* `pak1.pak`: contains episodes 2-4

These files aren't free to distribute, but `pak0.pak` is sufficient to run the game and it's freely available via the
[shareware version of Quake](http://bit.ly/2aDMSiz). Use [7-Zip](http://7-zip.org/) or a similar file archiver to extract
`quake106.zip/resource.1/ID1/PAK0.PAK`. Alternatively, if you own the game, you can obtain both .pak files from its install media.

Now locate your mtlQuake bundle, i.e. `mtlQuake.app`. You need to create an `id1` directory
next to that and copy `pak0.pak` there.

Then mtlQuake is ready to play.

Alternatively you can tell quake where the data folders are is when you launch it from the commandline. e.g. `./mtlQuake.app/Contents/MacOS/mtlQuake -basedir /Users/jamesu/External/Quake`

