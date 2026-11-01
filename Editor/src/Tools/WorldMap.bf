using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// World streaming in the editor (docs/world-streaming.md): the scene settings, the Always Loaded box, and the World
/// Map window that shows the grid of cells and loads or takes out the ones picked. Only the cells round the view are
/// loaded when a streamed world is opened; loading or taking out cells starts the undo history afresh.
extension EditorApp
{
	bool mShowWorldMap;
	/// Metres a pixel on the World Map.
	float mWorldMapScale = 4;
	WorldStreamer.State mPlayStreamingState ~ delete _;

	/// The World Streaming part of the Scene Settings. True when something changed.
	bool DrawStreamingSettings(SceneEnvironment env)
	{
		bool changed = false;
		if (!ImGui.CollapsingHeader("World Streaming") || !BeginPropertyTable("streaming"))
			return false;
		BeginProperty("Stream This Scene");
		changed |= ImGui.Checkbox("##stream", ref env.streaming);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Save the scene as a grid of cells, each in a file of its own beside it,\nand load only the cells near a Streaming Source (or a camera) while the game runs.");
		if (env.streaming)
		{
			BeginProperty("Cell Size");
			changed |= ImGui.DragFloat("##cell", ref env.streamCellSize, 1, 8, 2048, "%.0f m");
			BeginProperty("Load Radius");
			changed |= ImGui.DragFloat("##load", ref env.streamLoadRadius, 1, 0, 10000, "%.0f m");
			BeginProperty("Stand-in Radius");
			changed |= ImGui.DragFloat("##standin", ref env.streamStandInRadius, 5, 0, 50000, "%.0f m");
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("Cells this close that are not loaded show a merged, simpler stand-in.");
			BeginProperty("Floating Origin");
			changed |= ImGui.DragFloat("##origin", ref env.floatingOrigin, 10, 0, 100000, "%.0f m");
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("When the player is this far from the centre, the world moves back round them,\nkeeping precision far out. 0: never. Not used in network sessions.");
		}
		ImGui.EndTable();
		if (env.streaming && ImGui.Button("World Map"))
			mShowWorldMap = true;
		return changed;
	}

	/// The Always Loaded box under an object's name, in a streamed world.
	void DrawStreamingObject(GameObject gameObject)
	{
		if (!mScene.Environment.streaming || gameObject.IsFolder)
			return;
		var always = gameObject.AlwaysLoaded;
		if (ImGui.Checkbox("Always Loaded", ref always))
		{
			gameObject.AlwaysLoaded = always;
			MarkDirty();
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Kept loaded wherever the players are, instead of coming and going with its cell.");
		ImGui.SameLine();
		// Only objects at the top of the scene (or of folders) stream; the rest go with them.
		var top = gameObject;
		while (top.Transform.Parent != null && !top.Transform.Parent.GameObject.IsFolder)
			top = top.Transform.Parent.GameObject;
		if (!WorldStreamer.Streams(top))
			ImGui.TextDisabled(top == gameObject ? "(stays loaded)" : scope $"(stays loaded with {top.Name})");
		else
		{
			let key = WorldStreaming.Of(mScene).CellOf(mScene, top.Transform.Position);
			ImGui.TextDisabled(scope $"cell {WorldStreamer.KeyX(key)}, {WorldStreamer.KeyZ(key)}");
		}
	}

	/// After a streamed world was opened: the cells round the view come in, the others show their stand-ins.
	void LoadStreamedCellsAroundView()
	{
		if (!mScene.Environment.streaming || mScene.Streamer == null)
			return;
		let streamer = mScene.Streamer;
		// The game's camera, if the view has not been placed yet.
		streamer.LoadAround(mScene, mSceneCamera.position);
		if (streamer.Loaded.Count == 0)
		{
			for (let camera in mScene.Cameras)
			{
				streamer.LoadAround(mScene, camera.Transform.Position);
				break;
			}
		}
		streamer.ShowAllStandIns(mScene);
	}

	void StartPlayStreaming()
	{
		DeleteAndNullify!(mPlayStreamingState);
		if (mScene.Streamer != null)
			mPlayStreamingState = mScene.Streamer.SaveState();
	}

	void StopPlayStreaming()
	{
		if (mScene.Streamer != null && mPlayStreamingState != null)
		{
			mScene.Streamer.RestoreState(mPlayStreamingState);
			mScene.Streamer.ShowAllStandIns(mScene);
		}
		DeleteAndNullify!(mPlayStreamingState);
	}

	void DrawWorldMapWindow()
	{
		if (!mShowWorldMap)
			return;
		ImGui.SetNextWindowSize(.(520, 560), 4);
		if (!ImGui.Begin("World Map", &mShowWorldMap))
		{
			ImGui.End();
			return;
		}
		let env = mScene.Environment;
		if (!env.streaming)
		{
			ImGui.TextWrapped("This scene does not stream. Turn on Stream This Scene in the Scene Settings (click empty space in the Hierarchy).");
			ImGui.End();
			return;
		}
		let streamer = WorldStreaming.Of(mScene);
		let editing = mPlay == .Edit;
		ImGui.TextDisabled(scope $"{streamer.Cells.Count} cells, {streamer.Loaded.Count} loaded. Click a cell to load it, right-click to take it out.");
		if (!editing)
			ImGui.TextDisabled("Playing: the game streams by itself.");
		bool changed = false;
		if (editing)
		{
			if (ImGui.Button("Load Around View"))
			{
				streamer.LoadAround(mScene, mSceneCamera.position);
				changed = true;
			}
			ImGui.SameLine();
			if (ImGui.Button("Load All"))
			{
				let all = scope List<int64>(streamer.Cells.GetEnumerator());
				for (let key in all)
					streamer.LoadNow(mScene, key);
				changed = true;
			}
			ImGui.SameLine();
			if (ImGui.Button("Take Out All Far"))
			{
				let far = scope List<int64>();
				for (let key in streamer.Loaded)
				{
					if (streamer.Distance(mScene, key, mSceneCamera.position) > env.streamLoadRadius)
						far.Add(key);
				}
				for (let key in far)
					streamer.Unload(mScene, key, true);
				changed = true;
			}
		}
		ImGui.SetNextItemWidth(160);
		ImGui.SliderFloat("Metres a pixel", ref mWorldMapScale, 0.25f, 64);

		// The grid, centred on the view: each cell coloured by what it is.
		let origin = ImGui.GetCursorScreenPos();
		let avail = ImGui.GetContentRegionAvail();
		let size = ImGui.Vec2(Math.Max(avail.x, 64), Math.Max(avail.y, 64));
		ImGui.InvisibleButton("##map", size);
		let hovered = ImGui.IsItemHovered();
		ImGui.DrawRectFilled(origin, .(origin.x + size.x, origin.y + size.y), .(0.08f, 0.09f, 0.1f, 1));
		let centre = mSceneCamera.position + streamer.Origin;
		let cell = env.streamCellSize;
		let pixels = cell / mWorldMapScale;
		ImGui.Vec2 ToScreen(float x, float z) => .(origin.x + size.x * 0.5f + (x - centre.x) / mWorldMapScale, origin.y + size.y * 0.5f - (z - centre.z) / mWorldMapScale);
		let mouse = ImGui.GetMousePos();
		int64 under = 0;
		bool overCell = false;
		for (let key in streamer.Cells)
		{
			let a = ToScreen(WorldStreamer.KeyX(key) * cell, (WorldStreamer.KeyZ(key) + 1) * cell);
			let b = ImGui.Vec2(a.x + pixels, a.y + pixels);
			if (b.x < origin.x || b.y < origin.y || a.x > origin.x + size.x || a.y > origin.y + size.y)
				continue;
			let loaded = streamer.Loaded.Contains(key);
			let color = loaded ? Color(0.28f, 0.62f, 0.36f, 1) : (streamer.IsHeld(key) ? Color(0.75f, 0.6f, 0.25f, 1) : Color(0.25f, 0.3f, 0.38f, 1));
			ImGui.DrawRectFilled(.(a.x + 1, a.y + 1), .(b.x - 1, b.y - 1), color);
			if (hovered && mouse.x >= a.x && mouse.x < b.x && mouse.y >= a.y && mouse.y < b.y)
			{
				under = key;
				overCell = true;
				ImGui.DrawRect(a, b, .(1, 1, 1, 1), 0, 2);
			}
		}
		// The load radius round the view, and the view itself.
		let here = ToScreen(centre.x, centre.z);
		let r = env.streamLoadRadius / mWorldMapScale;
		ImGui.DrawRect(.(here.x - r, here.y - r), .(here.x + r, here.y + r), .(0.9f, 0.9f, 0.5f, 0.6f));
		ImGui.DrawRectFilled(.(here.x - 3, here.y - 3), .(here.x + 3, here.y + 3), .(1, 0.9f, 0.3f, 1));
		if (overCell)
		{
			let state = streamer.Loaded.Contains(under) ? "loaded" : (streamer.IsHeld(under) ? "taken out, not saved yet" : "not loaded");
			ImGui.SetTooltip(scope $"Cell {WorldStreamer.KeyX(under)}, {WorldStreamer.KeyZ(under)}: {state}" .CStr());
			if (editing && ImGui.IsMouseClicked(0) && !streamer.Loaded.Contains(under))
			{
				streamer.LoadNow(mScene, under);
				changed = true;
			}
			else if (editing && ImGui.IsMouseClicked(1) && streamer.Loaded.Contains(under))
			{
				streamer.Unload(mScene, under, true);
				changed = true;
			}
		}
		if (changed)
		{
			streamer.ShowAllStandIns(mScene);
			// Cells coming and going are not edits to undo.
			ResetUndo();
		}
		ImGui.End();
	}
}
