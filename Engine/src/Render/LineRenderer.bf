using System;
using System.Collections;

namespace Tallow;

/// A Line Renderer's settings and points, in its entity (LineRenderer is the handle). The data owns its point list
/// (HandleComponents.OwnLists): the engine copies and frees it with the component.
[Component, HandleData]
struct LineRendererData
{
	/// Whether the points are in the world (on) or relative to this object (off: the line moves with it).
	public bool useWorldSpace = true;
	/// Whether the last point joins back to the first.
	public bool loop = false;
	/// The line's width at its first point and its last, in metres.
	public float startWidth = 0.1f;
	public float endWidth = 0.1f;
	/// Its colour at the first point and the last, blended between. An alpha below 1 makes it see-through.
	public Color startColor = .White;
	public Color endColor = .White;
	/// View: turned to face the camera. Transform Z: flat, facing along this object's forward axis.
	public LineAlignment alignment = .View;
	/// Stretch: a texture once along the whole line. Tile: again every Tile Length.
	public LineTextureMode textureMode = .Stretch;
	/// With Tile: how long one repeat of the texture is, in metres.
	public float tileLength = 1;
	/// Draws it in dashes this long, in metres, with Gap Length between: 0 for a solid line. Dashes as long as the
	/// width make square dots.
	public float dashLength = 0;
	public float gapLength = 0.1f;
	/// A material (.tmat) to draw it with, for a see-through or additive one; empty draws it in its colours.
	public SharedString material = default;
	/// A texture laid along it (Texture Mode): across the image is across the line. Its alpha makes the line
	/// see-through, so a texture with clear parts draws only its solid ones.
	public SharedString texture = default;
	/// Whether it is drawn in its own colours, unlit by the scene's lights.
	public bool unlit = true;
	public bool castShadows = false;
	/// How strongly it glows in its own colours (through bloom): 0 not at all.
	[Range(0, 10)]
	public float glow = 0;
	/// Draws the line through this object's children, in order, instead of the points a script set: a way to lay one
	/// out in the editor.
	public bool childrenAsPoints = false;

	/// The points, in the world or this object's space (Use World Space). Edited in the Inspector and saved with the
	/// scene, or set by scripts (SetPositions, SetPosition, PositionCount, or this list itself).
	public List<Vector3> positions = new .() { .(0, 0, 0), .(0, 0, 1) };

	public this() { }
}

/// A line through a list of points, drawn as a flat strip that faces the viewer (docs/lines-and-trails.md): aim
/// guides, laser beams, cables, paths on a map. Its points are a list, edited in the Inspector or set by a script
/// (SetPositions, SetPosition, PositionCount); Children As Points draws it through this object's children instead. Its look
/// is its own (colours, Material, Texture, Glow), drawn through a hidden child object.
///
/// A handle (ComponentHandle): its settings are LineRendererData's fields; the strip it draws is its LineState.
[Component, HandleFields]
struct LineRenderer : ComponentHandle<LineRendererData>
{
	/// The point list, made if the data has none.
	List<Vector3> Points
	{
		get
		{
			ref List<Vector3> list = ref positions;
			if (list == null)
				list = new .();
			return list;
		}
	}

	/// How many points the line has. Setting it keeps the first ones and adds new points at the last one.
	public int PositionCount
	{
		get => Points.Count;
		set
		{
			let points = Points;
			let count = Math.Max(value, 0);
			if (count < points.Count)
				points.RemoveRange(count, points.Count - count);
			while (points.Count < count)
				points.Add(points.Count > 0 ? points.Back : .Zero);
		}
	}

	/// Changes one point.
	public void SetPosition(int index, Vector3 position)
	{
		let points = Points;
		if (index >= 0 && index < points.Count)
			points[index] = position;
	}

	/// One point, or zero for one that is not there.
	public Vector3 GetPosition(int index)
	{
		let points = Points;
		return (index >= 0 && index < points.Count) ? points[index] : .Zero;
	}

	/// Replaces every point.
	public void SetPositions(Span<Vector3> points)
	{
		let list = Points;
		list.Clear();
		for (let point in points)
			list.Add(point);
	}

	/// The whole line's length, in metres (in the world, with Use World Space; otherwise in this object's space).
	public float Length
	{
		get
		{
			let points = Points;
			float total = 0;
			for (int i = 1; i < points.Count; i++)
				total += (points[i] - points[i - 1]).Length;
			if (loop && points.Count > 2)
				total += (points[0] - points.Back).Length;
			return total;
		}
	}

	/// What it keeps between frames, with the settings copied in now.
	public LineState State
	{
		get
		{
			CheckValid();
			let state = ComponentState<LineState>.Make(mGameObject.Scene.World, mGameObject.Entity);
			state.[Friend]mGameObject = mGameObject;
			state.data = Data;
			return state;
		}
	}

	/// The Mesh Renderer that draws it (on a hidden child object), for changing what its fields do not cover. Not
	/// valid before its first frame.
	public MeshRenderer DrawnBy => State.[Friend]mRibbon.Renderer;

	/// Remakes the strip now from the current points (done each frame anyway).
	public void Rebuild() => State.Rebuild();

	/// In the editor, while not playing: every line is remade each frame (the Frame.OnFrame step).
	public static void FrameAll(Scene scene)
	{
		HideSwitchedOff(scene);
		if (scene.IsPlaying)
			return;
		for (let line in scene.Components<LineRenderer>(.. scope .()))
		{
			if (line.GameObject.ActiveInHierarchy)
				line.State.Rebuild();
		}
	}

	/// While playing: remade after the scripts' LateUpdate, once they have moved things.
	public static void LateAll(Scene scene)
	{
		for (let line in scene.Components<LineRenderer>(.. scope .()))
		{
			if (line.GameObject.ActiveInHierarchy)
				line.State.Rebuild();
		}
	}

	/// Lines switched off stop drawing.
	static void HideSwitchedOff(Scene scene)
	{
		for (let (entity, state) in ComponentState<LineState>.In(scene.World, .. scope .()))
		{
			let gameObject = state.GameObject;
			if (gameObject != null && !gameObject.GetComponent<LineRenderer>().enabled)
				state.[Friend]mRibbon.Detach();
		}
	}

	static void DrawGizmos(GameObject gameObject, bool selected)
	{
		if (!selected || gameObject.Scene == null)
			return;
		if (let state = ComponentState<LineState>.Get(gameObject.Scene.World, gameObject.Entity))
		{
			let points = state.[Friend]mPoints;
			for (int i = 1; i < points.Count; i++)
				Gizmos.Lines.Line(points[i - 1].position, points[i].position, Color(1, 0.8f, 0.2f, 1));
		}
	}

	static void OnRemove(void* world, uint64 entity)
	{
		if (let state = ComponentState<LineState>.Get((World)Internal.UnsafeCastToObject(world), Entity(entity)))
			state.[Friend]mRibbon.Remove();
		ComponentState<LineState>.Release(world, entity);
		HandleComponents.FreeLists(world, entity, typeof(LineRenderer));
	}
}

/// What a Line Renderer keeps between frames: the strip it draws (on a hidden child) and the points it was last
/// drawn through. `data` is a copy of the settings (its point list is the component's, only read here).
[DataFields(typeof(LineRendererData), "data")]
class LineState
{
	// Not `= .()`: that would make a point list of its own, which nothing frees.
	public LineRendererData data;

	GameObject mGameObject;
	Ribbon mRibbon = new .() ~ delete _;
	List<RibbonPoint> mPoints = new .() ~ delete _;

	public GameObject GameObject => mGameObject;
	Transform Transform => mGameObject.Transform;

	RibbonLook Look => .() { material = material, texture = texture, unlit = unlit, castShadows = castShadows, glow = glow };

	/// Remakes the strip from the current points.
	public void Rebuild()
	{
		mRibbon.Attach(mGameObject, Look);
		mPoints.Clear();
		let toWorld = Transform.LocalToWorld;
		if (childrenAsPoints)
		{
			for (let child in Transform.Children)
			{
				if (child.GameObject.ActiveInHierarchy && !child.GameObject.Transient)
					mPoints.Add(.() { position = child.Position });
			}
		}
		else if (positions != null)
		{
			for (let point in positions)
				mPoints.Add(.() { position = useWorldSpace ? point : toWorld.TransformPoint(point) });
		}
		let last = Math.Max(mPoints.Count - 1, 1);
		for (int i < mPoints.Count)
		{
			let t = i / (float)last;
			mPoints[i].width = Math.Max(Mathf.Lerp(startWidth, endWidth, t), 0);
			mPoints[i].color = Color.Lerp(startColor, endColor, t);
		}
		mRibbon.Build(Transform, mPoints, .() { alignment = alignment, textureMode = textureMode, loop = loop, dash = dashLength, gap = gapLength, tileLength = tileLength, textured = !texture.IsEmpty });
	}
}
