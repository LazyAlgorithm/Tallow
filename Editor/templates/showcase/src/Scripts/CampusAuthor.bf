using System;
using System.IO;
using Tallow;

namespace {NAMESPACE};

/// An explicit one-time export utility, separate from the scene's play lifecycle.
class CampusAuthor : Application
{
	Scene scene = new .() ~ delete _;
	Exhibition exhibition;
	String project = new .() ~ delete _;
	int frames;
	bool sculpted;
	int settle;
	public this()
	{
		Headless = true;
	}

	protected override bool OnInit()
	{
		Audio.NoDevice = true;
		if (!GetArg("--project", project)) return false;
		Assets.ProjectPath.Set(scope $"{project}/src");
		Scene.Active = scene;
		scene.Name.Set("Tallow Exhibition Campus");
		exhibition = scene.CreateGameObject("Exhibition Director").AddComponent<Exhibition>();
		exhibition.BuildForEditing();
		return true;
	}

	protected override void OnUpdate()
	{
		frames++;
		scene.Update();
		if (exhibition.terrain.ChunkCount > 0 && exhibition.terrain.PendingChunks == 0)
		{
			if (!sculpted)
			{
				sculpted = true;
				exhibition.terrain.ModifySphere(exhibition.exhibits[20].at + Vector3(0, 0.5f, 0), 4, 2);
			}
			else if (++settle > 8)
			{
				let ok = exhibition.SaveEditableCampus(project);
				Console.WriteLine(scope $"AUTHORED_SCENE_SAVED,{ok},{scene.Objects.Count}");
				Running = false;
			}
		}
		if (frames > 3000)
		{
			Console.WriteLine("AUTHORED_SCENE_SAVED,False,timeout");
			Running = false;
		}
	}
}
