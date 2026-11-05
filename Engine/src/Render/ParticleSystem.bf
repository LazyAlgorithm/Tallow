using System;
using System.Collections;

namespace Tallow;

/// A Particle System's settings, in its entity (ParticleSystem is the handle).
[Component, HandleData]
struct ParticleSystemData
{
	/// The mesh each particle is drawn with.
	public SharedString mesh = "builtin:cube";
	/// The most particles alive at once.
	public int32 maxParticles = 500;
	/// Particles per second.
	public float rate = 40.0f;
	/// Emit this many at once when the system starts (for explosions and puffs).
	public int32 burst = 0;
	/// Keeps emitting; off, it stops after one lifetime's worth.
	public bool looping = true;
	/// How long each particle lives, in seconds.
	public float lifetime = 2.0f;
	/// How fast particles leave, in metres a second.
	public float speed = 4.0f;
	/// How far from straight up (the object's +Y) particles may leave, in degrees: 0 a line, 180 every way.
	[Range(0, 180)]
	public float spreadAngle = 25.0f;
	/// Radius of the sphere particles start in.
	public float emitRadius = 0.1f;
	/// How particles are pulled, in metres a second squared.
	public Vector3 gravity = .(0, -4.0f, 0);
	/// How quickly particles slow down, as if through air.
	public float drag = 0.2f;
	/// How big a particle is when it is made.
	public float startSize = 0.25f;
	/// How big it is when it dies (in between, it changes evenly).
	public float endSize = 0.0f;
	/// How fast particles spin, in degrees a second.
	public float spinSpeed = 180.0f;
	/// A particle's colour when it is made.
	public Color startColor = .(1.0f, 0.75f, 0.3f, 1);
	/// Its colour when it dies.
	public Color endColor = .(0.8f, 0.15f, 0.05f, 1);
	/// Draws particles in their own colours, with no lighting (sparks, flames).
	public bool unlit = true;
	/// Simulate in world space, so moving the emitter leaves a trail.
	public bool worldSpace = true;

	public this() { }
}

/// Emits small meshes (cubes by default, which suits low-poly art) that move, shrink and fade.
/// A whole system is drawn as one instanced call. It previews in the editor without pressing Play.
///
/// A handle (ComponentHandle): its settings are ParticleSystemData's fields; the living particles are its
/// ParticleState, kept outside the data and freed with the component.
[Component, HandleFields]
struct ParticleSystem : ComponentHandle<ParticleSystemData>
{
	/// The particles, made the first time they are needed, with the settings copied in from the entity now.
	public ParticleState State
	{
		get
		{
			CheckValid();
			let state = ComponentState<ParticleState>.Make(mGameObject.Scene.World, mGameObject.Entity);
			state.[Friend]mGameObject = mGameObject;
			state.data = Data;
			return state;
		}
	}

	/// How many particles are alive now.
	public int32 AliveCount
	{
		get
		{
			if (!this)
				return 0;
			let state = ComponentState<ParticleState>.Get(mGameObject.Scene.World, mGameObject.Entity);
			return state != null ? state.AliveCount : 0;
		}
	}

	/// The box round the living particles, in the world.
	public Bounds WorldBounds => State.WorldBounds;

	/// Restarts the system, including its burst. In a network session, from the server or the object's owner, it
	/// plays on every machine.
	public void Play()
	{
		NetworkSync.ParticlesPlayed(this);
		State.Restart();
	}

	/// Moves every switched-on system on an active object on by a frame (the Frame.OnFrame step).
	public static void FrameAll(Scene scene)
	{
		for (let system in scene.Components<ParticleSystem>(.. scope .()))
		{
			if (system.GameObject.ActiveInHierarchy)
				system.State.Frame();
		}
	}

	static void OnRemove(void* world, uint64 entity) => ComponentState<ParticleState>.Release(world, entity);
}

/// A Particle System's living particles and what it keeps between frames. `data` is a copy of the settings.
[DataFields(typeof(ParticleSystemData), "data")]
class ParticleState
{
	public ParticleSystemData data = .();

	struct Particle
	{
		public Vector3 position;
		public Vector3 velocity;
		public Vector3 spin;
		public float age;
		public float lifetime;
		public float seed;
	}

	GameObject mGameObject;

	public GameObject GameObject => mGameObject;
	public Transform Transform => mGameObject.Transform;

	List<Particle> mParticles = new .() ~ delete _;
	float mEmitAccumulator;
	uint32 mRandom = 0x9e3779b9;
	bool mBurstDone;
	Bounds mBounds;

	/// How many particles are alive now.
	public int32 AliveCount => (int32)mParticles.Count;
	/// The box round the living particles, in the world.
	public Bounds WorldBounds => mBounds;

	/// Starts again, burst included (ParticleSystem.Play).
	public void Restart()
	{
		mParticles.Clear();
		mBurstDone = false;
		mEmitAccumulator = 0;
	}

	float Random01()
	{
		mRandom ^= mRandom << 13;
		mRandom ^= mRandom >> 17;
		mRandom ^= mRandom << 5;
		return (mRandom & 0xffffff) / 16777216.0f;
	}

	void Emit()
	{
		if (mParticles.Count >= maxParticles)
			return;
		Particle p;
		// Random direction inside a cone around the emitter's up axis.
		let cosLimit = Math.Cos(spreadAngle * Mathf.Deg2Rad);
		let cosAngle = Mathf.Lerp(1.0f, cosLimit, Random01());
		let sinAngle = Math.Sqrt(Math.Max(0, 1 - cosAngle * cosAngle));
		let around = Random01() * Mathf.PI * 2;
		var direction = Vector3(Math.Cos(around) * sinAngle, cosAngle, Math.Sin(around) * sinAngle);
		var offset = Vector3(Random01() - 0.5f, Random01() - 0.5f, Random01() - 0.5f) * (emitRadius * 2);
		if (worldSpace)
		{
			let rotation = Transform.Rotation;
			direction = rotation * direction;
			offset = Transform.Position + rotation * offset;
		}
		p.position = offset;
		p.velocity = direction * (speed * (0.75f + Random01() * 0.5f));
		p.spin = Vector3(Random01() - 0.5f, Random01() - 0.5f, Random01() - 0.5f) * (spinSpeed * 2);
		p.age = 0;
		p.lifetime = lifetime * (0.7f + Random01() * 0.6f);
		p.seed = Random01() * 360;
		mParticles.Add(p);
	}

	/// Emits and moves the particles (ParticleSystem.FrameAll, every frame, in the editor too).
	public void Frame()
	{
		let dt = Math.Min(Time.UnscaledDeltaTime, 0.05f);
		if (!mBurstDone)
		{
			for (int i < burst)
				Emit();
			mBurstDone = true;
		}
		if (looping || mParticles.Count > 0 || burst == 0)
		{
			if (looping)
			{
				mEmitAccumulator += rate * dt;
				while (mEmitAccumulator >= 1.0f)
				{
					Emit();
					mEmitAccumulator -= 1.0f;
				}
			}
		}

		let damping = Math.Exp(-drag * dt);
		var bounds = Bounds.Empty;
		for (int i = mParticles.Count - 1; i >= 0; i--)
		{
			var p = ref mParticles[i];
			p.age += dt;
			if (p.age >= p.lifetime)
			{
				mParticles.RemoveAtFast(i);
				continue;
			}
			p.velocity = (p.velocity + gravity * dt) * damping;
			p.position = p.position + p.velocity * dt;
			bounds.Encapsulate(p.position);
		}
		if (mParticles.Count == 0)
			bounds = .(Transform.Position, Transform.Position);
		else if (!worldSpace)
			bounds = bounds.Transformed(Transform.LocalToWorld);
		let pad = Vector3(Math.Max(startSize, endSize));
		mBounds = .(bounds.min - pad, bounds.max + pad);
	}

	/// Fills instance data (matrix then color, stride bytes apart) for the renderer.
	public void WriteInstances(Matrix4* data, int32 count, int32 stride)
	{
		let parent = worldSpace ? Matrix4.Identity : Transform.LocalToWorld;
		var cursor = (uint8*)data;
		for (int i < count)
		{
			let p = mParticles[i];
			let t = p.age / p.lifetime;
			let size = Mathf.Lerp(startSize, endSize, t);
			let rotation = Quaternion.Euler(p.spin * p.age + Vector3(p.seed));
			var world = Matrix4.TRS(p.position, rotation, .(size));
			if (!worldSpace)
				world = parent * world;
			*(Matrix4*)cursor = world;
			*(Color*)(cursor + sizeof(Matrix4)) = Color.Lerp(startColor, endColor, t);
			cursor += stride;
		}
	}
}
