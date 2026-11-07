using System;
using Tallow;

namespace {NAMESPACE};

/// The ordinary-script half of the courtyard crowd exhibit. Each object runs this familiar Update callback.
[Component]
class CrowdWalker : Script
{
	public Vector3 home;
	public float phase;

	public override void Update(TickInput input, float deltaTime)
	{
		phase += deltaTime;
		Transform.LocalPosition = home + Vector3(0, Math.Sin(phase) * 0.3f, 0);
	}
}

/// Optional advanced data for the same motion. Ordinary gameplay scripts do not need data queries.
[Component]
struct CrowdMotion
{
	public Vector3 home;
	public float phase;
}

/// Two small crowds with identical motion: blue objects use CrowdWalker, orange objects use a packed query.
/// Query ownership and iteration are shown here only as the advanced alternative to an ordinary script.
[Component]
class GalleryCrowd : Script
{
	Query<CrowdMotion, ObjectLink> mCrowd ~ delete _;

	public override void Start()
	{
		for (int group < 2)
		{
			for (int i < 36)
			{
				let home = Vector3(-5 + group * 12 + (i % 6) * 0.6f, 0.8f, -8 - (i / 6) * 0.6f);
				let member = Scene.CreateGameObject(group == 0 ? "Script crowd" : "System crowd", Transform);
				member.Transform.LocalPosition = home;
				member.Transform.LocalScale = .(0.24f, 0.55f, 0.24f);
				let renderer = member.AddComponent<MeshRenderer>();
				renderer.color = group == 0 ? Color(0.2f, 0.6f, 1) : Color(1, 0.55f, 0.2f);
				if (group == 0)
				{
					let walker = member.AddComponent<CrowdWalker>();
					walker.home = home;
					walker.phase = i * 0.25f;
				}
				else
					member.AddComponent<CrowdMotion>(.() { home = home, phase = i * 0.25f });
			}
		}
		mCrowd = new .(Scene.World, .ReadWrite, .Read);
	}

	public override void Update(TickInput input, float deltaTime)
	{
		if (mCrowd == null)
			return;
		for (var chunk in mCrowd)
		{
			let motion = chunk.Write<CrowdMotion>();
			let objects = chunk.Read<ObjectLink>();
			for (int i < chunk.Count)
			{
				let member = objects[i].gameObject;
				if (!member.ActiveInHierarchy)
					continue;
				motion[i].phase += deltaTime;
				member.Transform.LocalPosition = motion[i].home + Vector3(0, Math.Sin(motion[i].phase) * 0.3f, 0);
			}
		}
	}

	public override void OnGUI()
	{
		GUI.Label(20, GUI.Height - 36, "Courtyard crowds: blue = ordinary scripts; orange = optional advanced query. Same motion.");
	}
}
