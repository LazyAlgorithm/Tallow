using System;
using System.Collections;

namespace Tallow;

/// A Trail Renderer's settings, in its entity (TrailRenderer is the handle).
[Component, HandleData]
struct TrailRendererData
{
	/// How long a point stays in the trail, in seconds.
	public float time = 0.5f;
	/// How far the object moves before the trail gets a new point, in metres: smaller is smoother and costs more.
	public float minVertexDistance = 0.1f;
	/// Its width at the object and at the tail, in metres.
	public float startWidth = 0.2f;
	public float endWidth = 0.0f;
	/// Its colour at the object and at the tail, blended between. An alpha below 1 makes it see-through.
	public Color startColor = .White;
	public Color endColor = .(1, 1, 1, 0);
	/// Whether it is adding points. Off: what is there fades away, and starts again when it is turned back on.
	public bool emitting = true;
	/// View: turned to face the camera. Transform Z: flat, facing along this object's forward axis.
	public LineAlignment alignment = .View;
	/// Stretch: a texture once along the whole trail. Tile: again every Tile Length.
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
	/// Whether it also draws in the editor while not playing (as a still trail behind the object as it is dragged).
	public bool showInEditor = false;

	public this() { }
}

/// A trail left behind this object as it moves (docs/lines-and-trails.md): a flat strip facing the viewer through
/// where the object has been in the last Time seconds, thinning and fading towards its tail. Rockets, sword swings,
/// balls in flight, skid marks (with Transform Z alignment). Its look is its own
/// (colours, Material, Texture, Glow), drawn through a hidden child object, so it goes on anything, a ball's own
/// object included.
///
/// A handle (ComponentHandle): its settings are TrailRendererData's fields; the points it has left are its
/// TrailState.
[Component, HandleFields]
struct TrailRenderer : ComponentHandle<TrailRendererData>
{
	/// What it keeps between frames, with the settings copied in now.
	public TrailState State
	{
		get
		{
			CheckValid();
			let state = ComponentState<TrailState>.Make(mGameObject.Scene.World, mGameObject.Entity);
			state.[Friend]mGameObject = mGameObject;
			state.data = Data;
			return state;
		}
	}

	/// How many points the trail has now.
	public int PositionCount => State.[Friend]mSamples.Count;

	/// One point of the trail, oldest first, in the world.
	public Vector3 GetPosition(int index)
	{
		let samples = State.[Friend]mSamples;
		return (index >= 0 && index < samples.Count) ? samples[index].position : .Zero;
	}

	/// Removes the whole trail at once (after a teleport or a respawn, so it does not streak across the level).
	public void Clear() => State.[Friend]mSamples.Clear();

	/// The Mesh Renderer that draws it (on a hidden child object), for changing what its fields do not cover. Not
	/// valid before its first frame.
	public MeshRenderer DrawnBy => State.[Friend]mRibbon.Renderer;

	/// In the editor, while not playing: a trail is drawn only with Show In Editor (the Frame.OnFrame step).
	public static void FrameAll(Scene scene)
	{
		HideSwitchedOff(scene);
		if (scene.IsPlaying)
			return;
		for (let trail in scene.Components<TrailRenderer>(.. scope .()))
		{
			if (!trail.GameObject.ActiveInHierarchy)
				continue;
			let state = trail.State;
			if (!trail.showInEditor)
			{
				state.[Friend]mSamples.Clear();
				state.[Friend]mRibbon.Detach();
			}
			else
				state.[Friend]Step(Time.UnscaledDeltaTime);
		}
	}

	/// While playing: moved on after the scripts' LateUpdate, once they have moved things.
	public static void LateAll(Scene scene)
	{
		for (let trail in scene.Components<TrailRenderer>(.. scope .()))
		{
			if (trail.GameObject.ActiveInHierarchy)
				trail.State.[Friend]Step(Time.DeltaTime);
		}
	}

	/// A trail switched off stops drawing, and starts afresh when it is switched on again.
	static void HideSwitchedOff(Scene scene)
	{
		for (let (entity, state) in ComponentState<TrailState>.In(scene.World, .. scope .()))
		{
			let gameObject = state.GameObject;
			if (gameObject != null && !gameObject.GetComponent<TrailRenderer>().enabled)
			{
				state.[Friend]mSamples.Clear();
				state.[Friend]mRibbon.Detach();
			}
		}
	}

	static void DrawGizmos(GameObject gameObject, bool selected)
	{
		if (!selected || gameObject.Scene == null)
			return;
		if (let state = ComponentState<TrailState>.Get(gameObject.Scene.World, gameObject.Entity))
		{
			let points = state.[Friend]mPoints;
			for (int i = 1; i < points.Count; i++)
				Gizmos.Lines.Line(points[i - 1].position, points[i].position, Color(0.3f, 0.8f, 1, 1));
		}
	}

	static void OnRemove(void* world, uint64 entity)
	{
		if (let state = ComponentState<TrailState>.Get((World)Internal.UnsafeCastToObject(world), Entity(entity)))
			state.[Friend]mRibbon.Remove();
		ComponentState<TrailState>.Release(world, entity);
	}
}

/// What a Trail Renderer keeps between frames: the points it has left, its clock and the strip it draws (on a hidden
/// child). `data` is a copy of the settings.
[DataFields(typeof(TrailRendererData), "data")]
class TrailState
{
	public TrailRendererData data = .();

	struct Sample
	{
		public Vector3 position;
		public double time;
	}

	GameObject mGameObject;
	List<Sample> mSamples = new .() ~ delete _;
	Ribbon mRibbon = new .() ~ delete _;
	List<RibbonPoint> mPoints = new .() ~ delete _;
	double mClock;

	public GameObject GameObject => mGameObject;
	Transform Transform => mGameObject.Transform;

	RibbonLook Look => .() { material = material, texture = texture, unlit = unlit, castShadows = castShadows, glow = glow };

	void Step(float deltaTime)
	{
		mClock += Math.Max(deltaTime, 0);
		let here = Transform.Position;
		// Points older than Time drop off the tail.
		let life = Math.Max(time, 0.0001f);
		var expired = 0;
		while (expired < mSamples.Count && mClock - mSamples[expired].time > life)
			expired++;
		// Keeps one expired point while the next is alive, so the tail shrinks smoothly instead of jumping a segment.
		if (expired > 0 && expired < mSamples.Count)
			expired--;
		if (expired > 0)
			mSamples.RemoveRange(0, expired);
		if (mSamples.Count == 1 && mClock - mSamples[0].time > life)
			mSamples.Clear();

		if (emitting)
		{
			// The newest point is the object itself, moved along each frame; it stays once the object has gone
			// Min Vertex Distance past the one before it.
			if (mSamples.Count < 2 || (mSamples[mSamples.Count - 2].position - here).Length >= Math.Max(minVertexDistance, 0.001f))
				mSamples.Add(.() { position = here, time = mClock });
			else
				mSamples.Back = .() { position = here, time = mClock };
		}

		mRibbon.Attach(mGameObject, Look);
		mPoints.Clear();
		if (mSamples.Count >= 2)
		{
			for (int i < mSamples.Count)
			{
				let sample = mSamples[i];
				// 0 at the object, 1 at the end of its life.
				var t = (float)((mClock - sample.time) / life);
				t = Math.Clamp(t, 0, 1);
				// The tail point, already past its time, is moved in towards the next so the end slides in smoothly.
				var position = sample.position;
				if (i == 0 && mSamples.Count > 1 && mClock - sample.time > life)
				{
					let next = mSamples[1];
					let span = next.time - sample.time;
					if (span > 0)
					{
						let gone = Math.Clamp((float)((mClock - life - sample.time) / span), 0, 1);
						position = Vector3.Lerp(sample.position, next.position, gone);
					}
					t = 1;
				}
				mPoints.Add(.() { position = position, width = Math.Max(Mathf.Lerp(startWidth, endWidth, t), 0), color = Color.Lerp(startColor, endColor, t) });
			}
		}
		mRibbon.Build(Transform, mPoints, .() { alignment = alignment, textureMode = textureMode, loop = false, dash = dashLength, gap = gapLength, tileLength = tileLength, textured = !texture.IsEmpty });
	}

}
