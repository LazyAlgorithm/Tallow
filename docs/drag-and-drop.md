# Dragging in the editor

## Into Inspector fields

A field that holds an object (a `GameObject`, a `Transform` or a component, such as a Look At IK's Target) takes:

- a row dragged from the **Hierarchy**;
- an object dragged out of the **Scene view**: press on it and move the mouse before letting go;
- for asset fields (models, materials, textures, prefabs, sounds), a tile dragged from the **Project** panel.

A component field takes the first component of its type on the object dropped.

Pressing on a row, an object or a tile no longer selects it straight away. It is selected when you let go of the click without moving the mouse. So dragging something into a field leaves the Inspector on the object you are filling in. A click that does not move still selects as before, in the Hierarchy, the Scene view and the Project panel.

## The Inspector lock

The lock button beside the object's name in the Inspector keeps the Inspector on that object, whatever you select afterwards. Lock it, then select other objects, or click through the Project panel, and drag them into its fields. Press it again to make the Inspector follow the selection. The Inspector unlocks by itself if the object is deleted or another scene is opened.

## From Hierarchy into Project: create a prefab

Drag a GameObject row in **Hierarchy** onto a folder in **Project**, onto a
folder tile, or into the blank area of the current Project folder. Tallow
serializes the object and its children as a `.tprefab` in that folder.

The scene object remains in place. Existing assets are not overwritten:
`Crate.tprefab` becomes `Crate_2.tprefab` if the first name is taken.
The operation is available in Edit mode; creating prefab assets from
temporary Play-mode objects is disabled.

To rename a Hierarchy object, select it and click its name again, press **F2**
while the Hierarchy is focused, or choose **Rename** from the object's
right-click menu. Editing is inline; Enter commits and Escape cancels.
Double-click still frames the object in the Scene view.

## Into the Scene view

A prefab, a model or a map piece dragged from the Project panel over the Scene view is shown there before you let go. It is the object itself, standing on whatever surface the mouse points at (with snapping when it is on). Let go to place it: it is selected, as one undo step. Drag it back out of the view, or let go anywhere else, and it is gone again, with nothing to undo.

Other assets dropped on the Scene view do what they did before: a scene opens, an image becomes the selected object's texture, and an interface (`.tui`) becomes an object with a UI Document.

## Test

`--drag-test` drives the editor with a mouse of its own, frame by frame, as a person would. It checks:

- a Hierarchy row dragged into a field fills it without being selected;
- an object dragged out of the Scene view does the same;
- clicks in both still select;
- the lock;
- a prefab's preview while dragged, where it lands, and that it is one undo step;
- that a drag which leaves the view leaves nothing behind.

It logs `DRAG-TEST PASS` or `FAIL` and closes the editor.

On X11 (and XWayland), the SDL backend reads the real pointer each frame instead, so run it as `SDL_VIDEO_DRIVER=wayland Sandbox --editor --reset-layout --drag-test`. The test says so if it cannot move the mouse.
