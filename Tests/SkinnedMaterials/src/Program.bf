using System;
using System.Collections;
using Tallow;

namespace SkinnedMaterialTests;

/// Materials on skinned meshes (docs/skinned-materials.md): a rigged model's parts, one per material in the file, with
/// the file's own materials and textures (inside a .glb, as data: addresses, and as files beside the model), the
/// parts' own .tmat overrides, and saving. Run from this folder: BeefBuild -workspace=Tests/SkinnedMaterials -run
/// (the models are made by make_models.py). Drawing needs a graphics card; check it by eye in the editor.
class Program
{
	static int sFailures;
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		if (!pass)
			sFailures++;
		return pass;
	}

	static void CheckModel(StringView file)
	{
		let path = scope $"assets/{file}.glb";
		let model = SkinnedModel.Load(path);
		if (!Check(model != null, scope $"{file}: the rigged model loads"))
			return;
		Check(model.HasOwnMaterials && model.Parts.Count == 2, scope $"{file}: two materials, so two parts with materials of their own");
		if (model.Parts.Count != 2)
			return;
		let skin = model.Parts[0];
		let armour = model.Parts[1];
		Check(skin.name == "Skin" && armour.name == "Armour", scope $"{file}: parts are named after the file's materials");
		Check(skin.indices.Count == 6 && armour.indices.Count == 6, scope $"{file}: each part has its own triangles");
		Check(skin.material.texture == scope $"{path}#image0" && skin.material.normalMap == scope $"{path}#image1" , scope $"{file}: the base colour and normal textures come from the file");
		Check(Math.Abs(skin.material.normalStrength - 0.5f) < 0.001f && Math.Abs(skin.material.metallic - 0.1f) < 0.001f && Math.Abs(skin.material.roughness - 0.7f) < 0.001f, scope $"{file}: normal scale, metallic and roughness come from the file");
		Check(skin.material.blend == .Opaque && !skin.material.doubleSided && !skin.material.flatShading, scope $"{file}: an opaque, one-sided, smooth-shaded part");
		Check(armour.material.texture == scope $"{path}#image2" && armour.material.normalMap.IsEmpty, scope $"{file}: the second part has its own texture and no normal map");
		Check(armour.material.blend == .Cutout && Math.Abs(armour.material.cutoff - 0.4f) < 0.001f && armour.material.doubleSided, scope $"{file}: alpha mask and double sides come from the file");
		Check(armour.material.emissiveIntensity > 0 && armour.material.emissive.r > 0.1f && Math.Abs(armour.material.metallic - 0.9f) < 0.001f, scope $"{file}: emissive and metallic come from the file");
	}

	public static int Main(String[] args)
	{
		CheckModel("embedded");
		CheckModel("datauri");
		CheckModel("beside");

		let plain = SkinnedModel.Load("assets/plain.glb");
		Check(plain != null && !plain.HasOwnMaterials && plain.Parts.Count == 1, "a model with one plain material is one mesh, drawn as before");

		// ---- the component ----
		let scene = scope Scene();
		let hero = scene.CreateGameObject("Hero");
		hero.AddComponent<MeshRenderer>();
		let skinned = hero.AddComponent<SkinnedMeshRenderer>();
		skinned.model.Set("assets/embedded.glb");
		skinned.OnValidate();
		Check(skinned.PartCount == 2 && skinned.PartName(0) == "Skin" && skinned.PartName(1) == "Armour", "the component lists the model's parts");
		let path = scope String();
		skinned.SetPartMaterial(1, "Materials/steel.tmat");
		skinned.GetPartMaterial("Armour", path);
		Check(path == "Materials/steel.tmat", "a part can be given a material of its own");
		skinned.GetPartMaterial("Skin", path);
		Check(path.IsEmpty, "the other part keeps the model's");
		skinned.SetPartMaterial(0, "Materials/skin.tmat");
		Check(skinned.materials == "Armour=Materials/steel.tmat;Skin=Materials/skin.tmat", scope $"both are kept ({skinned.materials})");
		skinned.SetPartMaterial(1, "");
		skinned.GetPartMaterial("Armour", path);
		Check(path.IsEmpty && skinned.materials == "Skin=Materials/skin.tmat", "an empty path gives a part back the model's material");
		skinned.SetPartMaterial(0, "bad;path");
		skinned.SetPartMaterial(7, "Materials/x.tmat");
		Check(skinned.materials == "Skin=Materials/skin.tmat", "a path with ; or = and a part that does not exist are refused");

		let text = scope String();
		SceneSerializer.Save(scene, text);
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let back = loaded.Find("Hero").GetComponent<SkinnedMeshRenderer>();
		Check(back != null && back.materials == "Skin=Materials/skin.tmat", "a scene keeps the parts' materials");

		let plainObject = scene.CreateGameObject("Plain");
		plainObject.AddComponent<MeshRenderer>();
		let plainSkinned = plainObject.AddComponent<SkinnedMeshRenderer>();
		plainSkinned.model.Set("assets/plain.glb");
		plainSkinned.OnValidate();
		Check(plainSkinned.PartCount == 0, "a plain model has no parts to set");

		// ---- parts hidden, dyed or drawn only into shadows (a character customizer) ----
		skinned.SetPartHidden("Armour", true);
		skinned.SetPartColor("Skin", .(1, 0.5f, 0.25f));
		skinned.SetPartShadowOnly("Skin", true);
		skinned.OnFrame();
		let parts = hero.GetComponent<MeshRenderer>().RuntimeParts;
		Check(parts != null && parts.Count == 2 && parts[1].hidden && !parts[0].hidden, scope $"a part can be hidden ({skinned.hiddenParts})");
		Check(parts != null && Math.Abs(parts[0].tint.g - 0.5f) < 0.01f && Math.Abs(parts[0].tint.b - 0.25f) < 0.01f && parts[1].tint.r == 1, scope $"a part can be dyed, the others keep their colour ({skinned.partColors})");
		Check(parts != null && parts[0].shadowOnly && !parts[1].shadowOnly, "a part can be drawn only into shadows");
		skinned.SetPartHidden("Armour", false);
		skinned.SetPartShadowOnly("Skin", false);
		skinned.SetPartColor("Skin", .(0.2f, 0.3f, 0.4f));
		skinned.OnFrame();
		let redrawn = scope $"and shown and drawn again, dyed anew ({skinned.partColors})";
		Check(parts != null && !parts[1].hidden && !parts[0].shadowOnly && Math.Abs(parts[0].tint.r - 0.2f) < 0.01f && skinned.hiddenParts.IsEmpty && skinned.partColors == "Skin=0.2 0.3 0.4", redrawn);
		skinned.SetPartHidden("Armour", true);
		let looks = scope String();
		SceneSerializer.Save(scene, looks);
		let dressed = scope Scene();
		SceneSerializer.Load(dressed, looks);
		let again = dressed.Find("Hero").GetComponent<SkinnedMeshRenderer>();
		Check(again != null && again.hiddenParts == "Armour" && again.partColors == "Skin=0.2 0.3 0.4", "a scene keeps which parts are hidden and their colours");

		// ---- a clip library: clips made for the same skeleton, in another file ----
		{
			let model = SkinnedModel.Load("assets/plain.glb");
			let library = scope SkinnedModel();
			let turn = Quaternion.AngleAxis(90, .Up);
			for (int j < model.Joints.Count)
			{
				var joint = model.Joints[j];
				joint.name = new String(joint.name);
				// The library's rest pose differs: what is shared is each bone's turn from its rest.
				joint.restRotation = turn;
				joint.restPosition = .(5, 5, 5);
				library.Joints.Add(joint);
			}
			let walk = new SkinnedModel.Clip();
			walk.name.Set("Walk");
			walk.frames = 2;
			walk.duration = 1 / 30.0f;
			walk.data = new float[2 * library.Joints.Count * 10];
			let tilt = Quaternion.AngleAxis(30, .Right);
			for (int f < 2)
			{
				for (int j < library.Joints.Count)
				{
					let a = walk.data.Ptr + (f * library.Joints.Count + j) * 10;
					// Joint 0 rises 0.5 in the second frame; every joint tilts by 30 degrees from its rest.
					let position = Vector3(5, 5 + (j == 0 && f == 1 ? 0.5f : 0), 5);
					let rotation = turn * tilt;
					a[0] = position.x;
					a[1] = position.y;
					a[2] = position.z;
					a[3] = rotation.x;
					a[4] = rotation.y;
					a[5] = rotation.z;
					a[6] = rotation.w;
					a[7] = 1;
					a[8] = 1;
					a[9] = 1;
				}
			}
			library.Clips.Add(walk);
			let before = model.Clips.Count;
			Check(model.ImportClips(library, "library") == 1 && model.FindClip("Walk") != null && model.Clips.Count == before + 1, "a clip library's clips are added to a model with the same bones");
			Check(model.ImportClips(library, "library") == 0, "the same library is added once");
			let copy = model.FindClip("Walk");
			Vector3 p0, p1, s;
			Quaternion r;
			model.SampleJoint(copy, 1 / 30.0f, false, 0, out p1, out r, out s);
			model.SampleJoint(copy, 0, false, 0, out p0, out r, out s);
			let expected = (model.Joints[0].restRotation * tilt).Normalized;
			Check(Math.Abs(Quaternion.Dot(r, expected)) > 0.999f, "each bone turns from this model's rest as the library's bone turns from its own");
			Check((p0 - model.Joints[0].restPosition).Length < 0.001f && Math.Abs(p1.y - p0.y - 0.5f) < 0.001f, "a bone the clip moves keeps this model's place and takes the clip's movement");
			if (model.Joints.Count > 1)
			{
				model.SampleJoint(copy, 1 / 30.0f, false, 1, out p1, out r, out s);
				Check((p1 - model.Joints[1].restPosition).Length < 0.001f, "a bone the clip does not move stays where this model has it");
			}
		}

		Console.WriteLine(sFailures == 0 ? "All skinned material tests passed." : scope $"{sFailures} skinned material test(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
