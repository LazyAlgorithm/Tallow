using System;
using System.Collections;
using Tallow;

namespace ViewmodelTests;

/// The first-person viewmodel layer (docs/viewmodel.md): a camera's settings, which objects its pass takes, the
/// Inspector's layer choice for the setting, and saving. The pass itself draws on the graphics card, which this
/// fixture does not have; it is checked by eye in the Viewmodel sample scene.
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

	static bool Near(Matrix4 a, Matrix4 b)
	{
		for (int i < 16)
		{
			if (Math.Abs(a.m[i] - b.m[i]) > 0.0001f)
				return false;
		}
		return true;
	}

	public static int Main(String[] args)
	{
		ProjectConfig.Reset();
		ProjectConfig.Parse("""
			layer 0 "Default"
			layer 6 "Viewmodel"
			""");
		let viewmodelLayer = ProjectConfig.LayerNamed("Viewmodel");
		Check(viewmodelLayer == 6, "the project's Viewmodel layer is found by name");

		let scene = scope Scene();
		let cameraObject = scene.CreateGameObject("Eye");
		let camera = cameraObject.AddComponent<Camera>();
		let gun = scene.CreateGameObject("Gun");
		gun.Transform.SetParent(cameraObject.Transform, false);
		gun.Layer = viewmodelLayer;
		let crate = scene.CreateGameObject("Crate");

		// ---- off by default: every layer is drawn with the world ----
		var data = camera.GetCameraData(16.0f / 9.0f);
		Check(camera.viewmodelLayer == -1 && !data.hasViewmodel, "a new camera has no viewmodel pass");
		Check(!RenderView.DrawsAsViewmodel(data, gun) && !RenderView.DrawsAsViewmodel(data, crate), "without one, nothing is drawn as the viewmodel");
		CameraData editorCamera = default;
		Check(!editorCamera.hasViewmodel && !RenderView.DrawsAsViewmodel(editorCamera, gun), "a camera made by hand (the editor's own) draws everything with the world");

		// ---- on: the layer's objects go to the pass ----
		camera.viewmodelLayer = viewmodelLayer;
		camera.fieldOfView = 90;
		camera.viewmodelFieldOfView = 50;
		camera.viewmodelNearClip = 0.02f;
		data = camera.GetCameraData(16.0f / 9.0f);
		Check(data.hasViewmodel && data.viewmodelLayer == viewmodelLayer, "a viewmodel layer turns the pass on");
		Check(RenderView.DrawsAsViewmodel(data, gun), "an object on the viewmodel layer is drawn in the pass");
		Check(!RenderView.DrawsAsViewmodel(data, crate), "an object on another layer is drawn with the world");
		Check(!RenderView.DrawsAsViewmodel(data, null), "no object, no pass");
		Check(Near(data.viewmodelProjection, Matrix4.Perspective(50, 16.0f / 9.0f, 0.02f, 50.0f, Gfx.HomogeneousDepth)), "the pass uses the viewmodel's own field of view and near clip");
		Check(!Near(data.viewmodelProjection, data.projection), "and not the world's (90 degrees, 0.1 near)");
		Check(!data.viewmodelCastsShadows, "the viewmodel casts no shadow unless asked");
		camera.viewmodelCastsShadows = true;
		Check(camera.GetCameraData(1).viewmodelCastsShadows, "and does when asked");

		// ---- an orthographic camera has no viewmodel ----
		camera.orthographic = true;
		Check(!camera.GetCameraData(1).hasViewmodel, "an orthographic camera never draws a viewmodel pass");
		camera.orthographic = false;

		// ---- the Inspector shows the setting as a choice of layers ----
		List<FieldRef> fields = scope .();
		ComponentRegistry.GetFields(camera, fields);
		bool layerChoice = false, rangeOnFov = false;
		for (let field in fields)
		{
			if (field.name == "viewmodelLayer")
				layerChoice = field.isLayer && field.kind == .Int;
			if (field.name == "viewmodelFieldOfView")
				rangeOnFov = field.hasRange && field.rangeMin == 10 && field.rangeMax == 120;
		}
		Check(layerChoice, "viewmodelLayer is shown as a choice of the project's layers");
		Check(rangeOnFov, "viewmodelFieldOfView is a slider from 10 to 120");
		for (let field in fields)
		{
			if (field.name == "fieldOfView")
				Check(!field.isLayer, "other integer and number fields are not layer choices");
		}

		// ---- saving ----
		let text = scope String();
		SceneSerializer.Save(scene, text);
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let back = loaded.Find("Eye").GetComponent<Camera>();
		Check(back.viewmodelLayer == viewmodelLayer && back.viewmodelFieldOfView == 50 && Math.Abs(back.viewmodelNearClip - 0.02f) < 0.00001f && back.viewmodelCastsShadows, "a scene keeps the camera's viewmodel settings");
		Check(loaded.Find("Gun").Layer == viewmodelLayer, "and the weapon's layer");

		// An older scene, saved before the setting existed, reads as no viewmodel.
		let old = scope Scene();
		SceneSerializer.Load(old, """
			object 1 parent 0 active 1 name "Old"
			transform 0 0 0 0 0 0 1 1 1 1
			component Tallow.Camera enabled 1
			field fieldOfView 60
			""");
		Check(old.Find("Old").GetComponent<Camera>().viewmodelLayer == -1, "a camera from an older scene has no viewmodel");

		// ---- Viewmodel Pose: hip and aim, bob, sway, recoil ----
		let poseScene = scope Scene();
		let eye = poseScene.CreateGameObject("Eye");
		eye.AddComponent<Camera>();
		let arms = poseScene.CreateGameObject("Arms");
		arms.Transform.SetParent(eye.Transform, false);
		let pose = arms.AddComponent<ViewmodelPose>();
		Time.DeltaTime = 1.0f / 60;
		void Frames(int count)
		{
			for (int i < count)
				pose.LateUpdate();
		}
		bool Close(Vector3 a, Vector3 b, float within = 0.0005f) => (a - b).Length <= within;

		Frames(5);
		Check(Close(arms.Transform.LocalPosition, pose.hipPosition), "standing still and not aiming, the weapon is at the hip pose");
		pose.aiming = true;
		Frames(4);
		Check(pose.AimBlend > 0 && pose.AimBlend < 1, "raising it to aim takes a moment");
		Frames(30);
		Check(pose.AimBlend == 1 && Close(arms.Transform.LocalPosition, pose.aimPosition), "aimed, it is at the aim pose, in the middle");
		pose.aiming = false;
		Frames(30);
		Check(pose.AimBlend == 0 && Close(arms.Transform.LocalPosition, pose.hipPosition), "and back to the hip");

		// Walking: the camera moves along the ground; the weapon bobs, less when aiming.
		float Bob(bool aimed)
		{
			pose.aiming = aimed;
			Frames(40);
			float most = 0;
			for (int i < 120)
			{
				eye.Transform.Position = eye.Transform.Position + Vector3(0, 0, 5.0f / 60);
				pose.LateUpdate();
				let target = aimed ? pose.aimPosition : pose.hipPosition;
				most = Math.Max(most, (arms.Transform.LocalPosition - target).Length);
			}
			return most;
		}
		let hipBob = Bob(false);
		let aimBob = Bob(true);
		Check(hipBob > 0.005f, scope $"walking makes the weapon bob ({hipBob:0.0000} m)");
		Check(aimBob < hipBob * 0.5f, scope $"aiming steadies it ({aimBob:0.0000} m)");
		Frames(60);

		// Turning: the weapon lags behind the view a little, within the limit.
		pose.aiming = false;
		Frames(40);
		for (int i < 10)
		{
			eye.Transform.Rotation = Quaternion.Euler(0, (i + 1) * 3.0f, 0);
			pose.LateUpdate();
		}
		let held = arms.Transform.LocalRotation, rest = Quaternion.Euler(pose.hipRotation);
		let swayed = 2 * Math.Acos(Math.Min(Math.Abs(held.x * rest.x + held.y * rest.y + held.z * rest.z + held.w * rest.w), 1.0f)) * Mathf.Rad2Deg;
		Check(swayed > 0.5f && swayed <= pose.swayLimit * 1.6f, scope $"turning sways it, within the limit ({swayed:0.00} degrees)");

		// Recoil: back and up, then settles.
		Frames(120);
		pose.Kick(1);
		pose.LateUpdate();
		Check(arms.Transform.LocalPosition.z < pose.hipPosition.z - 0.01f, "a kick pushes the weapon back");
		Frames(120);
		Check(Close(arms.Transform.LocalPosition, pose.hipPosition, 0.002f), "and it settles back by itself");

		// The editor's buttons and preview.
		arms.Transform.LocalPosition = .(0.2f, -0.2f, 0.3f);
		pose.UseCurrentAsHip();
		Check(Close(pose.hipPosition, .(0.2f, -0.2f, 0.3f)), "Use current place as Hip takes the object's place");
		pose.preview = 1;
		pose.OnValidate();
		Check(Close(arms.Transform.LocalPosition, pose.aimPosition), "Preview at 1 shows the aim pose while not playing");
		pose.preview = 0;
		pose.OnValidate();
		Check(Close(arms.Transform.LocalPosition, pose.hipPosition), "and at 0 the hip pose");

		// Saved with the scene.
		pose.aimPosition = .(0.01f, -0.04f, 0.2f);
		let poseText = scope String();
		SceneSerializer.Save(poseScene, poseText);
		let poseLoaded = scope Scene();
		SceneSerializer.Load(poseLoaded, poseText);
		let poseBack = poseLoaded.Find("Arms").GetComponent<ViewmodelPose>();
		Check(poseBack != null && Close(poseBack.aimPosition, .(0.01f, -0.04f, 0.2f)) && Close(poseBack.hipPosition, .(0.2f, -0.2f, 0.3f)), "a scene keeps the poses");

		Console.WriteLine(sFailures == 0 ? "All viewmodel tests passed." : scope $"{sFailures} viewmodel test(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
