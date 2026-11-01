using System;
using System.Collections;
using Tallow;

namespace Tallow;

/// The built-in pieces of the editor's Map Builder and of a game's own map editor, in every project: the primitives,
/// and walls and floors for blocking out a level.
/// Each is named "builtin:<Folder>/<Name>" in the palette. Walls and floors are made of boxes with box colliders,
/// sized to whole and half metres so they line up with the move step; the object's origin is at its foot, in the
/// middle (a wall's origin is the middle of its bottom edge).
static class MapPieces
{
	public const String Prefix = "builtin:";

	const float WallHeight = 3;
	const float WallThickness = 0.2f;
	const float FloorThickness = 0.2f;
	const Color WallColor = .(0.86f, 0.86f, 0.84f, 1);
	const Color FloorColor = .(0.62f, 0.63f, 0.66f, 1);

	/// One box of a piece, in the piece's own space.
	struct Box
	{
		public Vector3 center;
		public Vector3 size;
		public float pitch;

		public this(Vector3 center, Vector3 size, float pitch = 0)
		{
			this.center = center;
			this.size = size;
			this.pitch = pitch;
		}
	}

	/// Every piece, in palette order.
	public static readonly StringView[?] Names = .(
		"builtin:Primitives/Cube", "builtin:Primitives/Sphere", "builtin:Primitives/Capsule", "builtin:Primitives/Cylinder",
		"builtin:Primitives/Cone", "builtin:Primitives/Plane", "builtin:Primitives/Quad",
		"builtin:Walls/Wall 4 m", "builtin:Walls/Wall 2 m", "builtin:Walls/Wall 1 m", "builtin:Walls/Half Wall 4 m",
		"builtin:Walls/Doorway 4 m", "builtin:Walls/Window Wall 4 m", "builtin:Walls/Pillar",
		"builtin:Floors/Floor 1 x 1", "builtin:Floors/Floor 2 x 2", "builtin:Floors/Floor 4 x 4", "builtin:Floors/Floor 8 x 8",
		"builtin:Floors/Ramp 4 m", "builtin:Floors/Stairs 4 m", "builtin:Floors/Platform 2 x 2");

	/// The palette folders, in order.
	public static readonly StringView[?] Folders = .("builtin:Primitives", "builtin:Walls", "builtin:Floors");

	public static bool IsPiece(StringView name) => name.StartsWith(Prefix);

	/// A folder's name as shown: "builtin:Walls" is "Walls".
	public static StringView FolderLabel(StringView folder) => IsPiece(folder) ? folder.Substring(Prefix.Length) : folder;

	/// Makes a piece in the scene, at the origin, and returns its root. Null for a name that is not a piece.
	public static GameObject Create(Scene scene, StringView name, Transform parent = null)
	{
		let slash = name.LastIndexOf('/');
		if (!IsPiece(name) || slash < 0)
			return null;
		let label = name.Substring(slash + 1);
		let folder = name.Substring(Prefix.Length, slash - Prefix.Length);
		if (folder == "Primitives")
			return CreatePrimitive(scene, label, parent);
		let boxes = scope List<Box>();
		if (!PieceBoxes(label, boxes))
			return null;
		let root = scene.CreateGameObject(label, parent);
		let color = folder == "Walls" ? WallColor : FloorColor;
		// The boxes are children, so the root stays unscaled with its origin at the foot.
		for (int i < boxes.Count)
			AddBox(scene.CreateGameObject(boxes.Count == 1 ? "Box" : scope $"Box {i + 1}" , root.Transform), boxes[i], color);
		return root;
	}

	static GameObject CreatePrimitive(Scene scene, StringView label, Transform parent)
	{
		let mesh = scope String();
		switch (label)
		{
		case "Cube": mesh.Set("builtin:cube");
		case "Sphere": mesh.Set("builtin:sphere");
		case "Capsule": mesh.Set("builtin:capsule");
		case "Cylinder": mesh.Set("builtin:cylinder");
		case "Cone": mesh.Set("builtin:cone");
		case "Plane": mesh.Set("builtin:plane");
		case "Quad": mesh.Set("builtin:quad");
		default: return null;
		}
		let made = scene.CreateGameObject(label, parent);
		made.AddComponent<MeshRenderer>().mesh.Set(mesh);
		return made;
	}

	/// A box as one object: a cube mesh scaled to the box, with a box collider.
	static void AddBox(GameObject part, Box shape, Color color)
	{
		part.Transform.LocalPosition = shape.center;
		part.Transform.LocalRotation = Quaternion.Euler(shape.pitch, 0, 0);
		part.Transform.LocalScale = shape.size;
		let renderer = part.AddComponent<MeshRenderer>();
		renderer.mesh.Set("builtin:cube");
		renderer.color = color;
		part.AddComponent<BoxCollider>();
	}

	/// The boxes that make a wall or floor piece.
	static bool PieceBoxes(StringView label, List<Box> boxes)
	{
		switch (label)
		{
		case "Wall 4 m": Wall(boxes, 4);
		case "Wall 2 m": Wall(boxes, 2);
		case "Wall 1 m": Wall(boxes, 1);
		case "Half Wall 4 m": boxes.Add(.(.(0, 0.75f, 0), .(4, 1.5f, WallThickness)));
		case "Doorway 4 m": WallWithOpening(boxes, 4, 1.25f, 0, 2.25f);
		case "Window Wall 4 m": WallWithOpening(boxes, 4, 1.5f, 1, 2.25f);
		case "Pillar": boxes.Add(.(.(0, WallHeight * 0.5f, 0), .(0.5f, WallHeight, 0.5f)));
		case "Floor 1 x 1": Floor(boxes, 1);
		case "Floor 2 x 2": Floor(boxes, 2);
		case "Floor 4 x 4": Floor(boxes, 4);
		case "Floor 8 x 8": Floor(boxes, 8);
		case "Platform 2 x 2": boxes.Add(.(.(0, 0.5f, 0), .(2, 1, 2)));
		case "Ramp 4 m":
			// Rises 1 m over 4 m, up towards +Z.
			let pitch = -Math.Atan2(1, 4) * 180 / Math.PI_f;
			boxes.Add(.(.(0, 0.5f, 0), .(2, FloorThickness, Math.Sqrt(17)), pitch));
		case "Stairs 4 m":
			// Eight steps of 0.25 m up 2 m over 4 m, towards +Z.
			for (int i < 8)
			{
				let height = 0.25f * (i + 1);
				boxes.Add(.(.(0, height * 0.5f, -2 + 0.25f + 0.5f * i), .(2, height, 0.5f)));
			}
		default: return false;
		}
		return true;
	}

	static void Wall(List<Box> boxes, float length)
	{
		boxes.Add(.(.(0, WallHeight * 0.5f, 0), .(length, WallHeight, WallThickness)));
	}

	/// A wall with a gap in the middle, width wide, from bottom to top above the floor.
	static void WallWithOpening(List<Box> boxes, float length, float width, float bottom, float top)
	{
		let side = (length - width) * 0.5f;
		boxes.Add(.(.(-(width + side) * 0.5f, WallHeight * 0.5f, 0), .(side, WallHeight, WallThickness)));
		boxes.Add(.(.((width + side) * 0.5f, WallHeight * 0.5f, 0), .(side, WallHeight, WallThickness)));
		boxes.Add(.(.(0, (top + WallHeight) * 0.5f, 0), .(width, WallHeight - top, WallThickness)));
		if (bottom > 0)
			boxes.Add(.(.(0, bottom * 0.5f, 0), .(width, bottom, WallThickness)));
	}

	static void Floor(List<Box> boxes, float size)
	{
		// The top is at the origin's height, so a floor placed on the ground is walked on at that height.
		boxes.Add(.(.(0, -FloorThickness * 0.5f, 0), .(size, FloorThickness, size)));
	}
}
