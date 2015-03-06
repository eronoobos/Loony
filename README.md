# Loony: Spring RTS meteor impact model map generator

### quick usage guide

clone this repo into \<Spring directory\>/maps/Loony.sdd/

run Spring with map "Loony v1"

hit enter to run commands:
	
/cheat

/globallos

/luaui loony shower 10

hit backslash to render the heightmap to the in-game map

hit enter to run command to generate all maps (height, attribute, metal) into Spring directory

/luaui loony renderall

### keys

hold down **.** and move the mouse to choose a meteor size, release to commit

**b** blur (takes forever, probably a bad idea)

**/** clear

**r** read heightmap from Spring

**\\** toggle writing heightmap to Spring (when off, displays meteor locations as UI ground circles)

**+** next mirroring type

**m** toggle underlying mare (a giant meteor impact preceding a shower)

**s** save

**l** load

### commands

all commands begin with **/luaui loony**

**shower \<number of meteors\>** do meteor shower

**renderall** render all images and files

**attributes** render attributes image

**height** render height map image

**metal** render metal map image and config lua file

**features** render feature config lua file (for geothermals)

**save \<name\>** save world to lua file with name

**load \<name\>** load world from lua file with name (warning: takes several minutes due to packet limits)