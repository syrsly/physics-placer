# Physics Placer

Version 1.0. Initial release. Come try out my PP!

Physics-based object placement for the Godot 4 3D editor. Three subtools live in one scene editor
tool: **Drop**, **Drag** and **Shoot**.

Requires Godot **4.x or newer**. Tested on **4.7.1**. Currently only supports 3D viewport.

## Install & Use

1. Copy the `addons/physics_placer` folder into your project or install from the official asset store/library.
2. Make sure the plugin *Physics Placer* is enabled at **Project -> Project Settings -> Plugins**.
3. The *Physics Placer* dock appears on the right of the 3D viewport. `Drop` / `Drag` / `Shoot` buttons are also added to the 3D viewport toolbar.

## How it works

Godot does not run physics on the scene you are editing. Physics Placer builds a hidden throwaway physics
bubble, copies the collision geometry of the current scene into it as static
bodies, and simulates temporary rigid bodies there. Your scene nodes are only used as a live preview
while the run happens; the final transforms are written once through the editor's undo/redo system,
so a single Ctrl+Z reverts a whole physics placement turn for every object moved or spawned.

## Subtools

### Dropper

Click the tool to activate that mode. Then, click an object in the viewport to select it for the Dropper.
Press **Drop Selection** in the dock or double-click the object to run the drop simulation.
The object falls and lands on whatever collider is beneath it: floor, table, shelf, or another prop.
Some limitations exist: You can't make in-game physics features interact with this drop sim,
so you can't for example drop an item on a fan to see the fan slow the object's descent.

### Dragger

Click the tool to activate it. Click an object and hold and drag to pull from the point you clicked.
The object is pulled by a clamped spring at the grab point and stays fully collidable while you move it,
so everything behaves physically:

- Push a book against a wall or the side of a desk and it leans naturally.
- Grab the rim of a basket and tip it; the apples inside roll out on their own (enable
  **Affect Scene Objects**).
- Tug a corner of a resting object and it pivots around that corner rather than teleporting.
- Shove a crate into a wall and it stops against it instead of passing through.

Controls: **mouse wheel** changes the grab depth, **Ctrl** locks movement to the vertical axis,
**Esc** exits the sim while in progress.

**Releasing the mouse stops the simulation immediately** and commits the object exactly where it is,
so you can leave it floating in mid-air if that is what you want.
Turn on **Let it settle after release** if you would rather it drop and come to rest first.
I find that the above option helps a ton when you want to toss objects around naturally.

### Shoot

A first-person weapon-like tool, and the only spawning tool. Aim in the viewport and click or hold
the left mouse button to shoot or spray objects in the direction you choose or toward the reticle attached
to the mouse cursor.

Unlike the other subtools, Shoot keeps a single physics simulation running while you fire and feeds
new rounds or object instances into it, so earlier rounds are still bouncing and settling as later ones
arrive and can be knocked around by each other. Releasing the trigger lets the whole volley settle,
then places every round in one step that can be undone in a single Ctrl+Z.

1. Pick the ammo scene object in the **Ammo** field.
2. Set **Shot force** and, if you want automatic fire, **Rate**.
3. Aim and click or hold the left mouse button.

## Performance

A volley of rounds settling is the heaviest thing the plugin does, so I've included a ton of optimization
options to help keep it performant and usable:

- **Park bodies once they settle** – Godot's own sleep thresholds almost never fire for a pile of
  resting props, so once a body settles, it is put to sleep explicitly. A later impact still wakes it.
- **Retire settled bodies from the sim** – after the volley ends, a body that has held still is
  removed from the physics space altogether. A sleeping body still carries its contact pairs; a
  retired one costs nothing. In a 200-round pile this took the late settle phase from 26.0 ms to
  14.0 ms per frame, against a 13.9 ms empty-editor baseline — the simulation becomes effectively
  free once things come to rest.
- **Preview refresh (Hz)** – how often simulated transforms are written back to your scene nodes.
  30 Hz looks smooth enough for the human eye, and it's a lot cheaper than rendering 90 Hz.
- **Radius** under *Environment* can be set to 10-20 so only nearby collision is gathered.
