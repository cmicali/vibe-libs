# ui/DropWells

The wells a drag of files over a window shows: dashed, rounded wells, each an SF Symbol over a label, with the one under the pointer lit. It depends on `core/Graphics`, for the tinted symbol. Its view came from Vibe's playlist drop zone. **It is macOS only.** Its files sit in its `Mac/` half. None reads an app's settings, strings, or types.

| File | Owns |
| --- | --- |
| `VibeDropWellsView.{h,m}` | the well, the style, and the view: the geometry, the light, the blur, the stacking, the fade, and the drawing |

## What the app supplies

**Which wells show is the app's.** It sets `wells`, an array of `VibeDropWell`, each a title, a symbol name, and an identifier. The identifier is the app's name for the well's action. The view reads none of them but to draw and to answer.

- **The style is the app's too** (`VibeDropWellsStyle`). `systemStyle` uses the label colors and the focus ring's color, which follow the appearance. An app with a fixed palette sets its own colors and font.
- **The blur is off by default** (`showsBlur`). An app turns it on over rows, so the wells read against them. Over an empty view it stays off.
- **A row of wells stacks below `minimumWellWidth`**, top to bottom. 0, the default, never stacks.
- **The fade is on by default** (`fadesStateChanges`). A caller that fades its own layer around the view turns it off, so the two fades don't stack.

## The geometry

**The wells sit 20 pt inside the view, 16 pt apart, in one row.** Each takes an equal share, floored. The last is anchored to the far edge, so the rounding slack lands in a gap. One well spans the whole inset view. Stacked, the same rules run top to bottom.

**A view too short for a well shows nothing and answers nothing** (`effectivelyVisible`). A host that collapses squashes the view to almost no height. The view also clips, since views don't clip by default.

## The drag

**The window is the dragging destination, never this view.** It forwards each location with `fileDragUpdatedAtWindowPoint:`, and the end with `fileDragEnded`. The first update shows the wells. Each later one moves the light, and redraws only when the lit well changes.

**`wellIdentifierAtWindowPoint:` is geometry alone.** It stays valid after `fileDragEnded`, since an app often delivers a drop after the drag session ends, once its expansion lands. So the app resolves the well at the drop, synchronously.

**The view takes no click** (`hitTest:` answers nil). The window beneath keeps its own. An app that wants a click on an empty well, as a rest state does, draws that well in its own view.

## Tests

`Tests/ui/DropWells/Mac/` holds `VibeDropWellsViewTests`: one, two, and three wells, the slack in the gap, the stacking, the light through a drag, the drop's read after the drag ends, a hidden and a squashed view, the blur, new wells dropping a light, and a draw with the system style. The window is kept off every display.
