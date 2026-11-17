using System;
using System.Collections;

namespace Tallow;

/// A Building's settings (docs/buildings.md). The plan (rooms, doors, windows, stairs) is drawn in the Scene view
/// with the Building tools and kept as text; the walls, floors and ceilings are made from it into the object's
/// Model Mesh whenever it changes.
[Component, HandleData]
struct BuildingData
{
	/// The rooms, doors, windows and stairs, as text (BuildingPlan). Drawn with the Building tools, not by hand.
	[HideInInspector]
	public String plan = new .();
	/// The squares rooms are drawn on, in metres.
	[Range(0.25f, 4)]
	public float gridSize = 0.5f;
	/// From one floor to the next, in metres.
	[Range(2, 12)]
	public float storeyHeight = 3;
	/// How thick walls are, in metres.
	[Range(0.05f, 1)]
	public float wallThickness = 0.2f;
	/// Floors, ceilings and the roof, in metres.
	[Range(0.02f, 1)]
	public float floorThickness = 0.2f;
	/// The walls' colour.
	public Color wallColor = .(0.88f, 0.87f, 0.84f);
	/// The ceilings' colour.
	public Color ceilingColor = .(0.96f, 0.96f, 0.95f);
	/// The roof's colour, where nothing is built above.
	public Color roofColor = .(0.55f, 0.56f, 0.6f);
	/// Each room's floor takes the room's own colour, so the plan is easy to read. Off: Floor Color everywhere.
	public bool roomColors = true;
	/// The floors' colour when rooms do not have their own (Room Colors off).
	public Color floorColor = .(0.62f, 0.6f, 0.56f);

	public this() { }
}

/// A building blocked out from a plan: rooms drawn on a grid, storey by storey. Walls go round every room by
/// themselves (one wall between two rooms), doors and windows are holes in them, each storey's floor is the
/// ceiling of the one below, and the top one gets a roof. Made into the object's Model Mesh, so it is drawn,
/// collides and is saved as any model is; Bake to Model (in the editor) keeps the mesh and drops the plan.
///
/// A handle (ComponentHandle): its settings are BuildingData's fields, in the object's entity.
[Component, HandleFields]
struct Building : ComponentHandle<BuildingData>
{
	/// Makes the walls again after the Inspector changes a setting, or after the scene is read (a no-op when the
	/// model already matches the plan).
	static void OnValidate(GameObject gameObject) => Rebuild(gameObject);

	/// Frees the plan's text with the component.
	static void OnRemove(void* world, uint64 entity) => HandleComponents.FreeLists(world, entity, typeof(Building));

	/// Makes the model from the plan, unless it already matches. False when the object has no Model Mesh.
	public static bool Rebuild(GameObject gameObject)
	{
		let building = gameObject.GetComponent<Building>();
		let model = gameObject.GetComponent<ModelMesh>();
		if (!building.IsValid || !model.IsValid)
			return false;
		let plan = scope BuildingPlan();
		plan.Read(building.plan);
		let mesh = scope EditMesh();
		BuildingGenerator.Generate(plan, BuildingGenerator.Settings.From(building), mesh);
		let text = scope String();
		mesh.Write(text);
		if (text != model.data)
			model.Set(mesh);
		return true;
	}
}

/// The plan of a Building: rooms (each on one storey, made of grid rectangles), doors and windows on walls, and
/// stairs. Rectangles are laid in order, so a later one paints over an earlier one; a rectangle of room 0 erases.
class BuildingPlan
{
	public class Room
	{
		public int32 id;
		public int32 storey;
		public String name = new .() ~ delete _;
		public Color color = .White;
	}

	public struct Rect
	{
		public int32 room;
		public int32 storey;
		/// Grid squares, min inclusive, max exclusive.
		public int32 x0, z0, x1, z1;
	}

	public enum OpeningKind
	{
		Door,
		Window,
		/// A wide gap with no door: an archway between two rooms.
		Opening
	}

	/// A hole in a wall. The wall runs along X (axis 0, on grid line z = line) or along Z (axis 1, on x = line).
	public struct Opening
	{
		public OpeningKind kind;
		public int32 storey;
		public int32 axis;
		public int32 line;
		/// Its middle along the wall, in metres from the building's origin.
		public float center;
		public float width;
		public float height;
		/// From the floor to its bottom (0 for doors and openings).
		public float sill;
	}

	/// A flight of stairs filling grid squares, climbing to the storey above in `direction` (0 +Z, 1 +X, 2 -Z,
	/// 3 -X). The floor above has a hole over it.
	public struct Stairs
	{
		public int32 storey;
		public int32 x0, z0, x1, z1;
		public int32 direction;
	}

	public List<Room> rooms = new .() ~ DeleteContainerAndItems!(_);
	public List<Rect> rects = new .() ~ delete _;
	public List<Opening> openings = new .() ~ delete _;
	public List<Stairs> stairs = new .() ~ delete _;
	public int32 nextRoom = 1;

	/// Soft colours rooms are given in turn.
	public static readonly Color[?] Palette = .(
		.(0.78f, 0.66f, 0.52f), .(0.56f, 0.68f, 0.78f), .(0.62f, 0.76f, 0.58f), .(0.82f, 0.62f, 0.62f),
		.(0.74f, 0.66f, 0.82f), .(0.84f, 0.78f, 0.52f), .(0.54f, 0.76f, 0.74f), .(0.8f, 0.64f, 0.74f));

	public static readonly StringView[?] OpeningNames = .("Door", "Window", "Opening");

	public Room FindRoom(int32 id)
	{
		for (let room in rooms)
		{
			if (room.id == id)
				return room;
		}
		return null;
	}

	public Room AddRoom(int32 storey)
	{
		let room = new Room();
		room.id = nextRoom++;
		room.storey = storey;
		room.name.AppendF("Room {}", room.id);
		room.color = Palette[(room.id - 1) % Palette.Count];
		rooms.Add(room);
		return room;
	}

	public int32 TopStorey
	{
		get
		{
			int32 top = 0;
			for (let rect in rects)
			{
				if (rect.room != 0)
					top = Math.Max(top, rect.storey);
			}
			return top;
		}
	}

	public void Clear()
	{
		ClearAndDeleteItems(rooms);
		rects.Clear();
		openings.Clear();
		stairs.Clear();
		nextRoom = 1;
	}

	public void CopyFrom(BuildingPlan from)
	{
		let text = scope String();
		from.Write(text);
		Read(text);
	}

	/// Drops what no longer stands on anything: rooms with no squares left, doors and windows with no wall under
	/// their middle, stairs on no room.
	public void Prune(float gridSize)
	{
		let grids = scope List<BuildingGrid>();
		defer { ClearAndDeleteItems(grids); }
		BuildingGrid Grid(int32 storey)
		{
			while (grids.Count <= storey)
			{
				let grid = new BuildingGrid();
				grid.Make(this, (int32)grids.Count);
				grids.Add(grid);
			}
			return grids[storey];
		}
		for (int i = rooms.Count - 1; i >= 0; i--)
		{
			let room = rooms[i];
			if (room.storey < 0 || !Grid(room.storey).Contains(room.id))
			{
				for (int r = rects.Count - 1; r >= 0; r--)
				{
					if (rects[r].room == room.id)
						rects.RemoveAt(r);
				}
				delete room;
				rooms.RemoveAt(i);
			}
		}
		for (int i = openings.Count - 1; i >= 0; i--)
		{
			let o = openings[i];
			let along = (int32)Math.Floor(o.center / gridSize);
			if (o.storey < 0 || !Grid(o.storey).IsWall(o.axis, o.line, along))
				openings.RemoveAt(i);
		}
		for (int i = stairs.Count - 1; i >= 0; i--)
		{
			let s = stairs[i];
			let grid = Grid(s.storey);
			bool any = false;
			for (int32 z = s.z0; z < s.z1 && !any; z++)
			{
				for (int32 x = s.x0; x < s.x1 && !any; x++)
					any = grid.Get(x, z) != 0;
			}
			if (!any)
				stairs.RemoveAt(i);
		}
	}

	public void Write(String text)
	{
		text.AppendF("building 1 {}\n", nextRoom);
		for (let room in rooms)
			text.AppendF("room {} {} {:0.###} {:0.###} {:0.###} {}\n", room.id, room.storey, room.color.r, room.color.g, room.color.b, room.name);
		for (let r in rects)
			text.AppendF("rect {} {} {} {} {} {}\n", r.room, r.storey, r.x0, r.z0, r.x1, r.z1);
		for (let o in openings)
			text.AppendF("open {} {} {} {} {:0.###} {:0.###} {:0.###} {:0.###}\n", (int32)o.kind, o.storey, o.axis, o.line, o.center, o.width, o.height, o.sill);
		for (let s in stairs)
			text.AppendF("stairs {} {} {} {} {} {}\n", s.storey, s.x0, s.z0, s.x1, s.z1, s.direction);
	}

	public void Read(StringView text)
	{
		Clear();
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.IsEmpty)
				continue;
			let words = scope List<StringView>();
			for (let word in line.Split(' ', .RemoveEmptyEntries))
				words.Add(word);
			if (words.IsEmpty)
				continue;
			int32 I(int i) => i < words.Count ? int32.Parse(words[i]) case .Ok(let v) ? v : 0 : 0;
			float F(int i) => i < words.Count ? float.Parse(words[i]) case .Ok(let v) ? v : 0 : 0;
			switch (words[0])
			{
			case "building":
				nextRoom = Math.Max(I(2), 1);
			case "room":
				let room = new Room();
				room.id = I(1);
				room.storey = I(2);
				room.color = .(F(3), F(4), F(5));
				// The name is the rest of the line, spaces and all.
				if (words.Count > 6)
					room.name.Set(StringView(words[6].Ptr, line.Ptr + line.Length - words[6].Ptr));
				rooms.Add(room);
				nextRoom = Math.Max(nextRoom, room.id + 1);
			case "rect":
				rects.Add(.() { room = I(1), storey = I(2), x0 = I(3), z0 = I(4), x1 = I(5), z1 = I(6) });
			case "open":
				openings.Add(.() { kind = (OpeningKind)Math.Clamp(I(1), 0, 2), storey = I(2), axis = I(3), line = I(4), center = F(5), width = F(6), height = F(7), sill = words.Count > 8 ? F(8) : 0 });
			case "stairs":
				stairs.Add(.() { storey = I(1), x0 = I(2), z0 = I(3), x1 = I(4), z1 = I(5), direction = I(6) & 3 });
			default:
			}
		}
	}
}

/// One storey of a plan as grid squares, each holding its room (0: none).
class BuildingGrid
{
	public int32 minX, minZ, width, depth;
	public int32[] cells ~ delete _;

	public void Make(BuildingPlan plan, int32 storey)
	{
		bool any = false;
		int32 x0 = 0, z0 = 0, x1 = 0, z1 = 0;
		for (let r in plan.rects)
		{
			if (r.storey != storey || r.room == 0 || r.x1 <= r.x0 || r.z1 <= r.z0)
				continue;
			if (!any)
			{
				x0 = r.x0; z0 = r.z0; x1 = r.x1; z1 = r.z1;
				any = true;
			}
			x0 = Math.Min(x0, r.x0); z0 = Math.Min(z0, r.z0);
			x1 = Math.Max(x1, r.x1); z1 = Math.Max(z1, r.z1);
		}
		minX = x0;
		minZ = z0;
		width = x1 - x0;
		depth = z1 - z0;
		delete cells;
		cells = new int32[Math.Max(width * depth, 1)];
		for (let r in plan.rects)
		{
			if (r.storey != storey)
				continue;
			for (int32 z = Math.Max(r.z0, minZ); z < Math.Min(r.z1, minZ + depth); z++)
			{
				for (int32 x = Math.Max(r.x0, minX); x < Math.Min(r.x1, minX + width); x++)
					cells[(z - minZ) * width + (x - minX)] = r.room;
			}
		}
	}

	public int32 Get(int32 x, int32 z)
	{
		if (x < minX || z < minZ || x >= minX + width || z >= minZ + depth)
			return 0;
		return cells[(z - minZ) * width + (x - minX)];
	}

	public bool Contains(int32 room)
	{
		for (let c in cells)
		{
			if (c == room)
				return true;
		}
		return false;
	}

	/// Whether there is a wall on grid line `line` (z for axis 0, x for axis 1) at square `along`: two different
	/// rooms (or a room and outside) meet there.
	public bool IsWall(int32 axis, int32 line, int32 along)
	{
		if (axis == 0)
			return Get(along, line - 1) != Get(along, line);
		return Get(line - 1, along) != Get(line, along);
	}

	/// Whether a post stands at grid point (x, z): walls meet, turn or end there (not one wall running straight on).
	public bool IsPost(int32 x, int32 z)
	{
		let west = IsWall(0, z, x - 1), east = IsWall(0, z, x);
		let south = IsWall(1, x, z - 1), north = IsWall(1, x, z);
		let count = (west ? 1 : 0) + (east ? 1 : 0) + (south ? 1 : 0) + (north ? 1 : 0);
		if (count == 0)
			return false;
		return !(count == 2 && ((west && east) || (south && north)));
	}

	/// The straight piece of wall (between two posts) through square `along` of a line, in squares [from, to).
	public bool WallRun(int32 axis, int32 line, int32 along, out int32 from, out int32 to)
	{
		from = to = along;
		if (!IsWall(axis, line, along))
			return false;
		bool Post(int32 at) => axis == 0 ? IsPost(at, line) : IsPost(line, at);
		from = along;
		while (!Post(from))
			from--;
		to = along + 1;
		while (!Post(to))
			to++;
		return true;
	}
}

/// Makes a Building's model from its plan.
static class BuildingGenerator
{
	public struct Settings
	{
		public float grid = 0.5f;
		public float storeyHeight = 3;
		public float wall = 0.2f;
		public float floor = 0.2f;
		public Color wallColor = .(0.88f, 0.87f, 0.84f);
		public Color ceilingColor = .(0.96f, 0.96f, 0.95f);
		public Color roofColor = .(0.55f, 0.56f, 0.6f);
		public Color floorColor = .(0.62f, 0.6f, 0.56f);
		public bool roomColors = true;
		/// Cut away (to see inside while working on a storey): the storeys above topStorey and its ceiling are left
		/// out.
		public bool cutaway = false;
		public int32 topStorey = int32.MaxValue;
		/// The walls of topStorey stop at this height above its floor (0: full height), as a cut-away.
		public float lowWalls = 0;

		public this() { }

		public static Settings From(Building building)
		{
			var s = Settings();
			s.grid = Math.Max(building.gridSize, 0.05f);
			s.storeyHeight = Math.Max(building.storeyHeight, 0.5f);
			s.wall = Math.Clamp(building.wallThickness, 0.01f, s.grid * 4);
			s.floor = Math.Clamp(building.floorThickness, 0.01f, s.storeyHeight * 0.5f);
			s.wallColor = building.wallColor;
			s.ceilingColor = building.ceilingColor;
			s.roofColor = building.roofColor;
			s.floorColor = building.floorColor;
			s.roomColors = building.roomColors;
			return s;
		}
	}

	/// Adds a box between two corners, its top, bottom and sides coloured.
	static void Box(EditMesh mesh, Vector3 min, Vector3 max, Color top, Color bottom, Color sides)
	{
		if (max.x - min.x < 0.0005f || max.y - min.y < 0.0005f || max.z - min.z < 0.0005f)
			return;
		let b = (int32)mesh.positions.Count;
		for (int i < 8)
			mesh.AddVertex(.((i & 1) != 0 ? max.x : min.x, (i & 2) != 0 ? max.y : min.y, (i & 4) != 0 ? max.z : min.z));
		void Face(int32 a, int32 c, int32 d, int32 e, Color color)
		{
			let face = new EditFace();
			face.Add(b + a, .Zero, color);
			face.Add(b + c, .Zero, color);
			face.Add(b + d, .Zero, color);
			face.Add(b + e, .Zero, color);
			mesh.faces.Add(face);
		}
		Face(0, 2, 3, 1, sides); // -Z
		Face(4, 5, 7, 6, sides); // +Z
		Face(0, 4, 6, 2, sides); // -X
		Face(1, 3, 7, 5, sides); // +X
		Face(2, 6, 7, 3, top); // +Y
		Face(0, 1, 5, 4, bottom); // -Y
	}

	/// A box in wall space: `a0..a1` along the wall, `w0..w1` across it, on axis 0 (along X) or 1 (along Z).
	static void WallBox(EditMesh mesh, int32 axis, float a0, float a1, float w0, float w1, float y0, float y1, Color color)
	{
		if (axis == 0)
			Box(mesh, .(a0, y0, w0), .(a1, y1, w1), color, color, color);
		else
			Box(mesh, .(w0, y0, a0), .(w1, y1, a1), color, color, color);
	}

	public static void Generate(BuildingPlan plan, Settings s, EditMesh mesh)
	{
		mesh.Clear();
		let top = s.cutaway ? Math.Min(plan.TopStorey, s.topStorey) : plan.TopStorey;
		let grids = scope List<BuildingGrid>();
		defer { ClearAndDeleteItems(grids); }
		for (int32 storey <= plan.TopStorey + 1)
		{
			let grid = new BuildingGrid();
			grid.Make(plan, storey);
			grids.Add(grid);
		}
		let g = s.grid, t = s.wall, h = s.storeyHeight, f = s.floor;
		for (int32 storey <= top)
		{
			let grid = grids[storey];
			if (grid.width == 0)
				continue;
			let y0 = storey * h;
			var y1 = y0 + h;
			if (s.cutaway && storey == top && s.lowWalls > 0)
				y1 = Math.Min(y1, y0 + f + s.lowWalls);
			// Posts where walls meet, turn or end.
			for (int32 z = grid.minZ; z <= grid.minZ + grid.depth; z++)
			{
				for (int32 x = grid.minX; x <= grid.minX + grid.width; x++)
				{
					if (grid.IsPost(x, z))
						Box(mesh, .(x * g - t / 2, y0, z * g - t / 2), .(x * g + t / 2, y1, z * g + t / 2), s.wallColor, s.wallColor, s.wallColor);
				}
			}
			// The walls between posts, with their doors and windows.
			for (int32 axis < 2)
			{
				let lineFrom = axis == 0 ? grid.minZ : grid.minX;
				let lineTo = axis == 0 ? grid.minZ + grid.depth : grid.minX + grid.width;
				let alongFrom = axis == 0 ? grid.minX : grid.minZ;
				let alongTo = axis == 0 ? grid.minX + grid.width : grid.minZ + grid.depth;
				for (int32 line = lineFrom; line <= lineTo; line++)
				{
					var along = alongFrom;
					while (along < alongTo)
					{
						if (!grid.WallRun(axis, line, along, let from, let to))
						{
							along++;
							continue;
						}
						WallSegment(plan, s, mesh, storey, axis, line, from * g + t / 2, to * g - t / 2, y0, y1);
						along = to;
					}
				}
			}
		}
		// Each level's slab: the floor of the storey on it and the ceiling of the one below (or its roof).
		// Cut away, the ceiling of the storey being worked on is left out.
		for (int32 level <= (s.cutaway ? top : top + 1))
			Slab(plan, s, mesh, grids, level);
		for (let stair in plan.stairs)
		{
			if (stair.storey <= top)
				Stairs(s, mesh, stair);
		}
	}

	/// A straight wall from `a0` to `a1` along it, with holes for the plan's doors and windows on it.
	static void WallSegment(BuildingPlan plan, Settings s, EditMesh mesh, int32 storey, int32 axis, int32 line, float a0, float a1, float y0, float y1)
	{
		if (a1 - a0 < 0.001f)
			return;
		let w = line * s.grid;
		let w0 = w - s.wall / 2, w1 = w + s.wall / 2;
		let floorTop = y0 + s.floor;
		// The holes on this piece, left to right.
		let holes = scope List<(float a0, float a1, float y0, float y1)>();
		for (let o in plan.openings)
		{
			if (o.storey != storey || o.axis != axis || o.line != line)
				continue;
			let h0 = Math.Max(o.center - o.width / 2, a0), h1 = Math.Min(o.center + o.width / 2, a1);
			if (h1 - h0 < 0.01f)
				continue;
			let bottom = floorTop + (o.kind == .Window ? Math.Max(o.sill, 0) : 0);
			holes.Add((h0, h1, bottom, Math.Min(bottom + o.height, y1)));
		}
		holes.Sort(scope (a, b) => a.a0 <=> b.a0);
		var at = a0;
		for (let hole in holes)
		{
			let h0 = Math.Max(hole.a0, at);
			if (hole.a1 <= h0)
				continue;
			WallBox(mesh, axis, at, h0, w0, w1, y0, y1, s.wallColor);
			if (hole.y0 > y0 + 0.001f)
				WallBox(mesh, axis, h0, hole.a1, w0, w1, y0, Math.Min(hole.y0, y1), s.wallColor);
			if (hole.y1 < y1 - 0.001f)
				WallBox(mesh, axis, h0, hole.a1, w0, w1, Math.Max(hole.y1, y0), y1, s.wallColor);
			at = hole.a1;
		}
		WallBox(mesh, axis, at, a1, w0, w1, y0, y1, s.wallColor);
	}

	/// The slab at the bottom of `level`: under that storey's rooms and over the rooms of the storey below, with
	/// holes over stairs. Its top is the floor (or the roof), its bottom the ceiling below.
	static void Slab(BuildingPlan plan, Settings s, EditMesh mesh, List<BuildingGrid> grids, int32 level)
	{
		let here = level < grids.Count ? grids[level] : null;
		let below = level > 0 ? grids[level - 1] : null;
		int32 x0 = int32.MaxValue, z0 = int32.MaxValue, x1 = int32.MinValue, z1 = int32.MinValue;
		for (let grid in BuildingGrid[2](here, below))
		{
			if (grid == null || grid.width == 0)
				continue;
			x0 = Math.Min(x0, grid.minX); z0 = Math.Min(z0, grid.minZ);
			x1 = Math.Max(x1, grid.minX + grid.width); z1 = Math.Max(z1, grid.minZ + grid.depth);
		}
		if (x0 >= x1 || z0 >= z1)
			return;
		let width = x1 - x0, depth = z1 - z0;
		// Each square's kind: 0 none, else the room on it + 1 (1: roof), times 2, plus 1 with a room below.
		let kinds = scope int32[width * depth];
		for (int32 z = z0; z < z1; z++)
		{
			for (int32 x = x0; x < x1; x++)
			{
				let room = here?.Get(x, z) ?? 0;
				let under = below?.Get(x, z) ?? 0;
				if (room == 0 && under == 0)
					continue;
				bool hole = false;
				for (let stair in plan.stairs)
					hole |= stair.storey == level - 1 && x >= stair.x0 && x < stair.x1 && z >= stair.z0 && z < stair.z1;
				if (hole)
					continue;
				kinds[(z - z0) * width + (x - x0)] = (room + 1) * 2 + (under != 0 ? 1 : 0);
			}
		}
		bool Covered(int32 x, int32 z) => x >= x0 && z >= z0 && x < x1 && z < z1 && kinds[(z - z0) * width + (x - x0)] != 0;
		let g = s.grid, t = s.wall;
		let y0 = level * s.storeyHeight;
		// Greedy rectangles of one kind.
		let done = scope bool[width * depth];
		for (int32 z = 0; z < depth; z++)
		{
			for (int32 x = 0; x < width; x++)
			{
				let kind = kinds[z * width + x];
				if (kind == 0 || done[z * width + x])
					continue;
				var w = 1;
				while (x + w < width && kinds[z * width + x + w] == kind && !done[z * width + x + w])
					w++;
				var d = 1;
				bool Row(int row)
				{
					for (int i < w)
					{
						if (kinds[row * width + x + i] != kind || done[row * width + x + i])
							return false;
					}
					return true;
				}
				while (z + d < depth && Row(z + d))
					d++;
				for (int j < d)
				{
					for (int i < w)
						done[(z + j) * width + x + i] = true;
				}
				let ax0 = x0 + x, az0 = z0 + z, ax1 = ax0 + (int32)w, az1 = az0 + (int32)d;
				// Each side tucks under this storey's wall along it, or reaches the outside of the wall below.
				float Side(int32 axis, int32 line, int32 from, int32 to, int32 outward)
				{
					bool allWall = here != null, allOpen = true;
					for (int32 a = from; a < to; a++)
					{
						if (here == null || !here.IsWall(axis, line, a))
							allWall = false;
						let ox = axis == 0 ? a : (outward < 0 ? line - 1 : line);
						let oz = axis == 0 ? (outward < 0 ? line - 1 : line) : a;
						if (Covered(ox, oz))
							allOpen = false;
					}
					if (allWall)
						return -t / 2;
					return allOpen ? t / 2 : 0;
				}
				let minX = ax0 * g - Side(1, ax0, az0, az1, -1), maxX = ax1 * g + Side(1, ax1, az0, az1, 1);
				let minZ = az0 * g - Side(0, az0, ax0, ax1, -1), maxZ = az1 * g + Side(0, az1, ax0, ax1, 1);
				let room = kind / 2 - 1;
				let roomInfo = room > 0 ? plan.FindRoom(room) : null;
				let topColor = room == 0 ? s.roofColor : (s.roomColors && roomInfo != null ? roomInfo.color : s.floorColor);
				let bottomColor = (kind & 1) != 0 ? s.ceilingColor : s.roofColor;
				Box(mesh, .(minX, y0, minZ), .(maxX, y0 + s.floor, maxZ), topColor, bottomColor, room == 0 ? s.roofColor : s.wallColor);
			}
		}
	}

	/// A flight of stairs from this storey's floor up to the next one's.
	static void Stairs(Settings s, EditMesh mesh, BuildingPlan.Stairs stair)
	{
		let g = s.grid;
		let bottom = stair.storey * s.storeyHeight + s.floor;
		let rise = s.storeyHeight;
		let steps = Math.Max((int)Math.Round(rise / 0.19f), 1);
		let minX = stair.x0 * g, maxX = stair.x1 * g, minZ = stair.z0 * g, maxZ = stair.z1 * g;
		let alongX = stair.direction == 1 || stair.direction == 3;
		let length = alongX ? maxX - minX : maxZ - minZ;
		let color = Color(0.72f, 0.7f, 0.66f);
		for (int i < steps)
		{
			var a = length * i / steps, b = length * (i + 1) / steps;
			// Climbing towards -X or -Z: the first step is at the far end.
			if (stair.direction >= 2)
			{
				let ta = length - b;
				b = length - a;
				a = ta;
			}
			let top = bottom + rise * (i + 1) / steps;
			if (alongX)
				Box(mesh, .(minX + a, bottom, minZ), .(minX + b, top, maxZ), color, color, color);
			else
				Box(mesh, .(minX, bottom, minZ + a), .(maxX, top, minZ + b), color, color, color);
		}
	}
}
