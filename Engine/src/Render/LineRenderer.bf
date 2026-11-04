using System;
using System.Collections;

namespace Tallow;

/// A line through a list of points, drawn as a flat strip that faces the viewer (docs/lines-and-trails.md): aim
/// guides, laser beams, cables, paths on a map. Its points are a list, edited in the Inspector or set by a script
/// (SetPositions, SetPosition, PositionCount); Children As Points draws it through this object's children instead. Its look
/// is its own (colours, Material, Texture, Glow), drawn through a hidden child object.
[Component]
class LineRenderer : Component
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
	public String material = new .() ~ delete _;
	/// A texture laid along it (Texture Mode): across the image is across the line. Its alpha makes the line
	/// see-through, so a texture with clear parts draws only its solid ones.
	public String texture = new .() ~ delete _;
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
	public List<Vector3> positions = new .() { .(0, 0, 0), .(0, 0, 1) } ~ delete _;

	Ribbon mRibbon = new .() ~ delete _;
	List<RibbonPoint> mPoints = new .() ~ delete _;

	/// How many points the line has. Setting it keeps the first ones and adds new points at the last one.
	public int PositionCount
	{
		get => positions.Count;
		set
		{
			let count = Math.Max(value, 0);
			if (count < positions.Count)
				positions.RemoveRange(count, positions.Count - count);
			while (positions.Count < count)
				positions.Add(positions.Count > 0 ? positions.Back : .Zero);
		}
	}

	/// Changes one point.
	public void SetPosition(int index, Vector3 position)
	{
		if (index >= 0 && index < positions.Count)
			positions[index] = position;
	}

	/// One point, or zero for one that is not there.
	public Vector3 GetPosition(int index) => (index >= 0 && index < positions.Count) ? positions[index] : .Zero;

	/// Replaces every point.
	public void SetPositions(Span<Vector3> points)
	{
		positions.Clear();
		for (let point in points)
			positions.Add(point);
	}

	/// The whole line's length, in metres (in the world, with Use World Space; otherwise in this object's space).
	public float Length
	{
		get
		{
			float total = 0;
			for (int i = 1; i < positions.Count; i++)
				total += (positions[i] - positions[i - 1]).Length;
			if (loop && positions.Count > 2)
				total += (positions[0] - positions.Back).Length;
			return total;
		}
	}

	RibbonLook Look => .() { material = material, texture = texture, unlit = unlit, castShadows = castShadows, glow = glow };

	/// The Mesh Renderer that draws it (on a hidden child object), for changing what its fields do not cover. Null
	/// before its first frame.
	public MeshRenderer DrawnBy => mRibbon.Renderer;

	public override void OnDestroy() => mRibbon.Remove();
	public override void OnUnregister() => mRibbon.Detach();
	public override void OnDisable() => mRibbon.Detach();

	public override void OnFrame()
	{
		// While playing, LateUpdate draws it, after the scripts have moved things.
		if (!Scene.IsPlaying)
			Rebuild();
	}

	public override void LateUpdate() => Rebuild();

	/// Remakes the strip now from the current points (done each frame anyway).
	public void Rebuild()
	{
		if (!IsActiveAndEnabled)
			return;
		mRibbon.Attach(this, Look);
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
		else
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

	public override void OnDrawGizmos(bool selected)
	{
		if (!selected)
			return;
		for (int i = 1; i < mPoints.Count; i++)
			Gizmos.Lines.Line(mPoints[i - 1].position, mPoints[i].position, Color(1, 0.8f, 0.2f, 1));
	}
}
