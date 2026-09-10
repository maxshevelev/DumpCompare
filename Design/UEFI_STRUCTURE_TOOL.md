# UEFI Structure — tool-module plan

A **structure browser** for a UEFI firmware image: it reads the open file
through the pane's shared `LazyUEFITree`, shows that tree in an expandable
outline, and — for the one node the user has selected — draws its bytes in the
dump and explains what they are.

This is the "structure browser" `Design/TOOL_MODULES_PLAN.md` named but did not
build. It stands on the same seam as the FIT tool-module and reads the same
shared parser; what it adds is a tree, a per-node zone, and a per-node detail.

**In scope.** The `Modules/UEFITool` package (a pure target and a UI target, as
every tool-module has), the outline, the splitter, the detail, the one zone per
selected node, and the app wiring (registry + `project.yml`).

**Not in scope.** Editing the image (this tool reads; the FIT tool writes),
decompressing compressed sections (the parser keeps them whole, §6), and
persistence beyond the session's parked selection.

## What it shows

The panel is two halves, split by a vertical splitter:

- **Top — the tree.** An `NSOutlineView` over the pane's shared `LazyUEFITree`.
  Every node is a row; a container expands. The row is the node's name, with its
  kind and size in a secondary column. Nothing here is built up ahead of time,
  and nothing below the top level is even read: opening the panel yields the
  top level, and a row the reader opens materializes that one branch off the
  main actor, with a "Loading…" row in its place while it does.
- **Bottom — the detail.** A label/value list describing the *selected* node,
  by its type. A volume shows its file system, length and attributes; a file its
  name GUID, type and state; a microcode its signature and revision; and so on.
  The fields come from the node's header, read through the same `ImageReader`
  the parser used, so what the detail says is what the bytes say.

A line under the tree says when something is being read, the way the FIT panel
does. The bar beside it is indeterminate: what the panel waits for is a branch
of the tree or a node's checksums, and neither is a fraction of the image the
reader would recognise.

**The title.** The summary line names what the image *is* and counts nothing —
the tree behind it is materialized branch by branch, so a node count would be a
count of clicks. A wrapper root (an Intel image, the "UEFI image" the parser
groups several tops under, a capsule) folds into that title and its children
open the outline; a real root the file already had — a lone volume off a chip —
keeps its row, because folding it would mean deciding again the moment somebody
opened it.

## The one zone

Selecting a node publishes **one** zone: that node's range, focused. Nothing
else. A UEFI parse is a tree of thousands of nodes and drawing all of them in
the dump is how the hex view stops being readable — what is worth drawing is
the node the user is looking at, and that changes with the selection.

The zone's id is the node's path (`1.2.0`), which is stable across a re-parse of
the same image and is also the route a diagnostic about a node three levels down
needs. When the user picks that zone back in the dump — the host has already
selected the bytes — the panel expands the tree to that node and selects it.

Before anything is selected the map is empty: a parse that has landed but a
node nobody has chosen yet draws nothing, and that is the honest state.

## The detail, by type

The common fields every node has — kind, name, subtype, GUID, the header/body/
tail ranges, the whole range, the flags, and the physical address when the image
told us one — are shown for every kind. On top of that, each kind reads its own
header:

| Kind | What the header adds |
| --- | --- |
| volume | file system (GUID + name), `FvLength`, signature, attributes, header length, checksum, revision, extended-header offset |
| file | name GUID, type (code + name), attributes, size, state, header and body checksums |
| section | type (code + name), size |
| microcode | header type, update revision, date (BCD), processor signature, checksum, loader revision, platform ids, data and total size |
| capsule | capsule GUID (+ name), header size, flags, image size |
| flash descriptor | signature, FLMAP, version |
| region | the region's base and limit, from the descriptor's table |
| padding / free space / non-UEFI data | nothing but the size the common fields already carry |

The offsets and the name tables (`FFS.typeName`, `Section.typeName`,
`KnownGUIDs`, `FlashRegionType.label`, `MicrocodeHeader.date`) all live in
`UEFIImage`; the detail builder reads them through the reader and does not
re-derive a single one.

## Where the decisions live

As with the FIT tool-module, the panel is thin and the pure target is where the
decisions are made and tested by `swift test` over hand-built images:

- **`UEFITool`** (pure): the zone for a node, the trip back from a zone id to a
  node id, and the detail for a node. No AppKit.
- **`UEFIToolUI`**: the module, the session (read the pane's tree, show,
  publish, park the selection), and the view controller (the outline, the
  splitter, the detail).

The session holds no tree of its own. It reads the pane's `LazyUEFITree` — one
per open file, shared with the FIT and ME Analyzer tool-modules, and kept for as
long as the file is — and subscribes to it, so a branch any of them opens
reaches this panel's rows. Only the selected `NodeID` is the session's, kept by
path so it survives an edit that left its node where it was.

Three things the panel needs are asked for rather than computed up front:

- **A branch**, when a row is opened. `LazyUEFITree.expand` runs the volume's
  file walk or the region's signature scan off the main actor and coalesces a
  second request onto one already in flight.
- **The mapping**, the first time a node is in focus. It is what the detail's
  Address row reads, and it comes from the Volume Top File — whose last byte is
  at the top of the address space, so it is at the end of the last container of
  the image. One descent down the chain that reaches the last byte finds it; a
  panel nobody has clicked in pays for none of it.
- **Checksums**, per branch, as each one appears. A pass reads whole file
  bodies, so each branch is read exactly once and a reader who never opens a
  volume never pays for its files.

A content change does not re-read the file. `PaneUEFIState.invalidate` has
already told the tree which of its branches the edit made stale — the volume or
region it landed in, and nothing beside it — so the panel shows what is left and
the reader re-opens whatever they want back.

## Stages

Each stage builds, tests, and is committable on its own.

1. **Package.** `Modules/UEFITool` with the two targets and the ten-line
   `ToolContentByteSource` adapter, wired into `project.yml` and the registry.
   Empty for now: it builds and the menu lists it.
2. **The pure target.** The zone builder, the zone-id trip back, and the detail
   builder for every kind, with a `swift test` suite over images built byte by
   byte (the `UEFIImage` `TestImage` builders, reused).
3. **The view.** The outline over the tree, the splitter, the detail list, and
   the progress line. The session that reads the pane's tree and publishes the
   one zone.
4. **The app.** The module in the registry, the package in the binary, and the
   app's flow tests: open an image, select a node, and check the zone and the
   detail.
