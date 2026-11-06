using System;
using System.Collections;

namespace Tallow.Editor;

/// Window > Network: the running session (play mode with --host or --connect, or a Network Session in the scene), each
/// client with the bytes a second sent to it, and each shared object with what the engine chose for it and why
/// (NetworkIdentity.automatic) and what it costs. NetworkManager.Describe gives the same as text.
extension EditorApp
{
	bool mShowNetwork;
	List<(int32 id, int32 bytesPerSecond, int32 inputsWaiting)> mNetworkClients = new .() ~ delete _;
	List<(StringView kind, int32 bytes)> mNetworkKinds = new .() ~ delete _;

	/// --network-window opens it at start.
	void ApplyNetworkSwitches()
	{
		if (HasArg("--network-window"))
			mShowNetwork = true;
	}

	void DrawNetworkWindow()
	{
		if (!mShowNetwork)
			return;
		let viewport = ImGui.GetMainViewport();
		ImGui.SetNextWindowPos(.(viewport.workPos.x + 80, viewport.workPos.y + 80), 4);
		ImGui.SetNextWindowSize(.(980, 560), 4);
		if (ImGui.Begin("Network", &mShowNetwork))
			DrawNetworkContents();
		ImGui.End();
	}

	void DrawNetworkContents()
	{
		let network = mScene?.Network;
		if (network == null)
		{
			ImGui.TextWrapped("No session. Press Play in a scene with a Network Session, or start the editor with --host or --connect <address>. Objects with a Network Identity are shared; what the engine chooses for each is shown here.");
			return;
		}
		let role = network.IsServer ? (network.LocalClientId == 0 ? "host" : "server") : (network.IsClient ? "client" : "offline");
		ImGui.Text(scope $"{role}, tick {network.Tick}: {network.Identities.Count} shared objects, {network.BytesSentPerSecond} bytes a second sent, {network.BytesReceivedPerSecond} received");
		if (network.IsServer)
		{
			mNetworkClients.Clear();
			network.ClientStats(mNetworkClients);
			if (mNetworkClients.IsEmpty)
				ImGui.Text("No clients yet.");
			else if (ImGui.BeginTable("netclients", 3, ImGui.TableFlags.SizingStretchProp))
			{
				ImGui.TableSetupColumn("Client");
				ImGui.TableSetupColumn("Bytes a second to it");
				ImGui.TableSetupColumn("Controls waiting");
				ImGui.TableHeadersRow();
				for (let client in mNetworkClients)
				{
					ImGui.TableNextRow();
					ImGui.TableNextColumn();
					ImGui.Text(scope $"{client.id}");
					ImGui.TableNextColumn();
					ImGui.Text(scope $"{client.bytesPerSecond}");
					ImGui.TableNextColumn();
					ImGui.Text(scope $"{client.inputsWaiting}");
				}
				ImGui.EndTable();
			}
		}
		mNetworkKinds.Clear();
		network.BytesByKind(mNetworkKinds);
		if (!mNetworkKinds.IsEmpty)
		{
			let line = scope String("Sent over the last second:");
			for (let kind in mNetworkKinds)
				line.AppendF(" {} {} bytes,", kind.kind, kind.bytes);
			line.RemoveFromEnd(1);
			ImGui.TextWrapped(line);
		}
		ImGui.Separator();
		if (!ImGui.BeginTable("netobjects", 6, ImGui.TableFlags.SizingStretchProp))
			return;
		ImGui.TableSetupColumn("Object");
		ImGui.TableSetupColumn("Owner");
		ImGui.TableSetupColumn("Taken as");
		ImGui.TableSetupColumn("Format");
		ImGui.TableSetupColumn("Bytes/s");
		ImGui.TableSetupColumn("Why");
		ImGui.TableHeadersRow();
		let why = scope String();
		for (let identity in network.IdentityStates)
		{
			ImGui.TableNextRow();
			ImGui.TableNextColumn();
			if (ImGui.Selectable(scope $"{identity.GameObject.Name}##net{identity.NetId}", mSelectedId == identity.GameObject.Id))
				mSelectedId = identity.GameObject.Id;
			ImGui.TableNextColumn();
			ImGui.Text(identity.ownerId == 0 ? "server" : scope $"client {identity.ownerId}");
			ImGui.TableNextColumn();
			ImGui.Text(scope $"{identity.ChosenKind}");
			ImGui.TableNextColumn();
			ImGui.Text(scope $"{identity.Chosen.remoteFormat}");
			ImGui.TableNextColumn();
			ImGui.Text(scope $"{identity.BytesPerSecond}");
			ImGui.TableNextColumn();
			why.Clear();
			if (network.IsServer)
				identity.Explain(network, why);
			else
				why.Append(identity.ownerId == network.LocalClientId ? "this machine's own: predicted" : (identity.Predicted ? "predicted" : "shown a moment in the past"));
			ImGui.TextWrapped(why);
		}
		ImGui.EndTable();
	}
}
