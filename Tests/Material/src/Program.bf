using System;
using System.Collections;
using System.IO;
using Tallow;
using Tallow.Editor;

namespace MaterialTests;

/// Materials, custom surface shaders and compute shaders, without a graphics card: the data, the shader source
/// the editor generates, and real compiles of that source with the engine's shader compiler.
class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	const String cFolder = "/tmp/tallow-material-test";

	static void EngineRoot(String output, String file = Compiler.CallerFilePath)
	{
		var path = (StringView)file;
		for (int i < 4)
		{
			let slash = path.LastIndexOf('/');
			if (slash > 0)
				path = path.Substring(0, slash);
		}
		output.Set(path);
	}

	static int64 Size(StringView path)
	{
		List<uint8> data = scope .();
		return (File.ReadAll(path, data) case .Ok) ? data.Count : -1;
	}

	public static int Main(String[] args)
	{
		bool ok = true;
		let root = scope String();
		EngineRoot(root);
		Directory.CreateDirectory(scope $"{cFolder}/Shaders").IgnoreError();
		Assets.ProjectPath.Set(cFolder);

		// ---- a material ----
		{
			let fresh = scope Material();
			ok &= Check(fresh.shader.IsEmpty && fresh.color == Color.White && fresh.blend == .Opaque && fresh.tiling.x == 1 && !fresh.doubleSided && fresh.normalMap.IsEmpty, "a new material is the standard opaque surface");
			let made = Material.Create("Materials/brass.tmat");
			made.color = .(0.9f, 0.7f, 0.3f, 1);
			made.metallic = 1;
			made.roughness = 0.3f;
			made.flatShading = false;
			made.texture.Set("Textures/brass.png");
			made.normalMap.Set("Textures/brass_n.png");
			made.normalStrength = 0.6f;
			made.metallicRoughnessMap.Set("Textures/brass_mr.png");
			made.occlusionMap.Set("Textures/brass_ao.png");
			made.occlusionStrength = 0.8f;
			made.emissiveMap.Set("Textures/brass_e.png");
			made.tiling = .(4, 2);
			made.offset = .(0.5f, 0);
			made.blend = .Cutout;
			made.cutoff = 0.3f;
			made.doubleSided = true;
			made.shader.Set("Shaders/glow.tshader");
			made.SetFloat("speed", 2.5f);
			made.SetColor("tint", .(1, 0, 0, 1));
			made.SetTexture("detail", "Textures/d.png");
			Directory.CreateDirectory(scope $"{cFolder}/Materials").IgnoreError();
			made.Save(scope $"{cFolder}/Materials/saved.tmat");
			let loaded = Material.Load("Materials/saved.tmat");
			let detail = scope String();
			loaded?.GetTexture("detail", detail);
			ok &= Check(loaded != null && loaded != made && loaded.metallic == 1 && Math.Abs(loaded.roughness - 0.3f) < 0.0001f && !loaded.flatShading && loaded.texture == "Textures/brass.png"
				&& loaded.tiling.x == 4 && loaded.offset.x == 0.5f && loaded.blend == .Cutout && Math.Abs(loaded.cutoff - 0.3f) < 0.0001f && loaded.doubleSided && loaded.shader == "Shaders/glow.tshader"
				&& loaded.GetFloat("speed") == 2.5f && loaded.GetColor("tint").r == 1 && loaded.GetColor("tint").g == 0 && detail == "Textures/d.png", "a material saves and loads: surface settings, tiling, blending, shader and the shader's values");
			ok &= Check(loaded != null && loaded.normalMap == "Textures/brass_n.png" && Math.Abs(loaded.normalStrength - 0.6f) < 0.0001f && loaded.metallicRoughnessMap == "Textures/brass_mr.png" && loaded.occlusionMap == "Textures/brass_ao.png"
				&& Math.Abs(loaded.occlusionStrength - 0.8f) < 0.0001f && loaded.emissiveMap == "Textures/brass_e.png", "and its PBR maps: normal, metallic-roughness, occlusion and emissive");
			let first = scope String(), second = scope String();
			made.Write(first);
			loaded.Write(second);
			ok &= Check(first == second, "saving what was loaded writes the same file");
			ok &= Check(Material.Load("Materials/saved.tmat") == loaded && Material.Load("Materials/nope.tmat") == null, "loading the same file twice gives the same material; a missing file gives none");
			let copy = loaded.Clone();
			copy.SetFloat("speed", 9);
			copy.color = .(0, 0, 1, 1);
			ok &= Check(copy.GetFloat("speed") == 9 && loaded.GetFloat("speed") == 2.5f && loaded.color.r == 0.9f && copy.normalMap == loaded.normalMap, "a copy changes without changing the original");
			delete copy;
			let before = loaded.Revision;
			loaded.SetFloat("speed", 2.5f);
			let same = loaded.Revision;
			loaded.SetFloat("speed", 3);
			ok &= Check(same == before && loaded.Revision > before, "setting a value to what it already is changes nothing; a real change is noticed");
		}

		// ---- shader files ----
		let surfaceSource = """
            // A pulsing glow.
            property float speed = 2
            property color tint = 1 0.5 0.2 1
            property vector wave = 0.1 3 0 0
            property texture detail

            surface {
                float pulse = 0.5 + 0.5 * sin(time * speed + worldPosition.x);
                albedo *= tint.rgb * texture2D(detail, uv * 4.0).rgb;
                emissive += tint.rgb * pulse;
                if (pulse > 0.9) { roughness = 0.1; }
            }

            vertex {
                position.y += sin(time + position.x * wave.y) * wave.x;
            }
            """;
		File.WriteAllText(scope $"{cFolder}/Shaders/glow.tshader" , surfaceSource).IgnoreError();
		{
			let shader = ShaderAsset.Load("Shaders/glow.tshader");
			ok &= Check(shader != null && shader.problems.IsEmpty && shader.properties.Count == 4 && !shader.IsCompute, "a shader file is read without complaint");
			let speed = shader?.Find("speed"), tint = shader?.Find("tint"), wave = shader?.Find("wave"), detail = shader?.Find("detail");
			ok &= Check(speed != null && speed.type == .Float && speed.defaultValue.x == 2 && speed.slot == 0 && tint != null && tint.type == .Color && tint.defaultValue.y == 0.5f && tint.slot == 1
				&& wave != null && wave.type == .Vector && wave.defaultValue.y == 3 && wave.slot == 2 && detail != null && detail.type == .Texture && detail.slot == 0, "its properties have their types, defaults and slots");
			ok &= Check(shader.surface.Contains("emissive += tint.rgb * pulse;") && shader.surface.Contains("if (pulse > 0.9) { roughness = 0.1; }") && !shader.surface.Contains("position.y") && shader.vertex.Contains("position.y +="), "the surface and vertex blocks are kept apart, braces inside them and all");
			// A material using it: unset values fall back to the shader's defaults.
			let material = scope Material();
			material.shader.Set("Shaders/glow.tshader");
			material.SetFloat("speed", 7);
			Vector4[ShaderAsset.MaxValues] values = default;
			StringView[ShaderAsset.MaxTextures] textures = default;
			material.SetTexture("detail", "Textures/noise.png");
			material.GatherValues(ref values, ref textures);
			ok &= Check(values[0].x == 7 && values[1].y == 0.5f && values[2].y == 3 && textures[0] == "Textures/noise.png" && material.GetFloat("speed") == 7 && material.GetColor("tint").g == 0.5f, "a material hands the shader what was set, and the shader's defaults for the rest");

			let fragment = scope String(), vertex = scope String(), compute = scope String();
			ok &= Check(ShaderCompiler.Generate(shader, root, fragment, vertex, compute) && fragment.Contains("#define speed u_params[0].x") && fragment.Contains("#define tint u_params[1]") && fragment.Contains("#define detail s_texture1")
				&& fragment.Contains("emissive += tint.rgb * pulse;") && fragment.Contains("shadeSurface(") && vertex.Contains("#define wave u_params[2]") && vertex.Contains("position.y += sin(") && !vertex.Contains("s_texture1"),
				"the generated shader is the engine's lit shader with the properties and the code put in");
		}
		{
			let bad = scope ShaderAsset();
			bad.Parse("property matrix m\nproperty float 9lives\nproperty float a\nproperty float a\nwibble\nsurface {\n albedo = vec3(1.0, 0.0, 0.0);\n");
			ok &= Check(bad.problems.Contains("unknown property type 'matrix'") && bad.problems.Contains("line 2") && bad.problems.Contains("line 4") && bad.problems.Contains("line 5: expected") && bad.problems.Contains("missing its closing }") && bad.properties.Count == 1, "mistakes in a shader file are reported by line");
			let many = scope String();
			for (int i < 9)
				many.AppendF("property float v{}\n", i);
			for (int i < 3)
				many.AppendF("property texture t{}\n", i);
			bad.Parse(many);
			ok &= Check(bad.properties.Count == 10 && bad.problems.Contains("line 9: too many") && bad.problems.Contains("line 12: too many"), "eight values and two textures are the most a shader can declare");
		}

		// ---- real compiles ----
		let log = scope String();
		let compiled = ShaderCompiler.Compile(root, "Shaders/glow.tshader", log);
		let name = scope String();
		ShaderAsset.CompiledName("Shaders/glow.tshader", name);
		let fsSize = Size(scope $"{cFolder}/Shaders/Compiled/spirv/{name}_fs.bin"), vsSize = Size(scope $"{cFolder}/Shaders/Compiled/spirv/{name}_vs.bin");
		ok &= Check(compiled && fsSize > 2000 && vsSize > 500, scope $"the surface shader compiles for Vulkan ({fsSize} and {vsSize} bytes) {log}");
		int others = 0;
		for (let folder in StringView[?]("glsl", "essl", "metal"))
		{
			if (Size(scope $"{cFolder}/Shaders/Compiled/{folder}/{name}_fs.bin") > 500)
				others++;
		}
		ok &= Check(others == 3, scope $"and for the other backends ({others} of 3: OpenGL, OpenGL ES, Metal)");

		File.WriteAllText(scope $"{cFolder}/Shaders/broken.tshader" , "surface {\n\talbedo = notAThing * 2.0;\n}\n").IgnoreError();
		log.Clear();
		let brokenOk = ShaderCompiler.Compile(root, "Shaders/broken.tshader", log);
		let brokenName = scope String();
		ShaderAsset.CompiledName("Shaders/broken.tshader", brokenName);
		ok &= Check(!brokenOk && log.Contains("broken.tshader") && log.Contains("fragment stage") && log.Contains("notAThing") && Size(scope $"{cFolder}/Shaders/Compiled/spirv/{brokenName}_fs.bin") < 0, scope $"a shader with a mistake fails with the compiler's message and leaves no compiled file ({log.Substring(0, Math.Min(log.Length, 110))..Trim()})");

		File.WriteAllText(scope $"{cFolder}/Shaders/ripple.tcompute" , """
            property float speed = 1
            property color ink = 0.2 0.6 1 1
            compute {
                // Fade what was there, and draw a ring that grows from the middle.
                float ring = abs(distance(uv, vec2(0.5, 0.5)) - fract(time * speed * 0.2) * 0.7);
                result = result * 0.96 + ink * smoothstep(0.02, 0.0, ring);
                result.a = 1.0;
            }
            """).IgnoreError();
		{
			let shader = ShaderAsset.Load("Shaders/ripple.tcompute");
			let fragment = scope String(), vertex = scope String(), compute = scope String();
			ok &= Check(shader != null && shader.IsCompute && shader.properties.Count == 2 && ShaderCompiler.Generate(shader, root, fragment, vertex, compute) && compute.Contains("IMAGE2D_WO(s_target, rgba8, 0)") && compute.Contains("#define ink u_params[1]") && compute.Contains("smoothstep(0.02, 0.0, ring)") && fragment.IsEmpty, "a compute shader file becomes a compute program's source");
			log.Clear();
			let ran = ShaderCompiler.Compile(root, "Shaders/ripple.tcompute", log);
			let computeName = scope String();
			ShaderAsset.CompiledName("Shaders/ripple.tcompute", computeName);
			let csSize = Size(scope $"{cFolder}/Shaders/Compiled/spirv/{computeName}_cs.bin");
			ok &= Check(ran && csSize > 500, scope $"and compiles for Vulkan ({csSize} bytes) {log}");
			let precise = scope ShaderAsset();
			precise.Parse("precision high\ncompute {\n result = result + vec4(0.5, 0.0, 0.0, 0.0);\n}\n");
			compute.Clear();
			ok &= Check(precise.highPrecision && ShaderCompiler.Generate(precise, root, fragment, vertex, compute) && compute.Contains("rgba16f"), "\"precision high\" keeps values as 16-bit floats");
			log.Clear();
			File.WriteAllText(scope $"{cFolder}/Shaders/wrong.tcompute" , "surface {\n albedo = vec3(1.0, 1.0, 1.0);\n}\n").IgnoreError();
			ok &= Check(!ShaderCompiler.Compile(root, "Shaders/wrong.tcompute", log) && log.Contains("needs a compute"), "a .tcompute file without a compute block is refused with a reason");
			ok &= Check(!Compute.Supported && !Compute.Run(shader, null), "with no graphics card (as here) compute reports itself unsupported and does nothing");
		}
		// Only what changed is compiled again.
		{
			File.Delete(scope $"{cFolder}/Shaders/broken.tshader").IgnoreError();
			File.Delete(scope $"{cFolder}/Shaders/wrong.tcompute").IgnoreError();
			log.Clear();
			let failed = ShaderCompiler.CompileProject(root, log);
			let stamp = File.GetLastWriteTimeUtc(scope $"{cFolder}/Shaders/Compiled/spirv/{name}_fs.bin");
			System.Threading.Thread.Sleep(1100);
			File.WriteAllText(scope $"{cFolder}/Shaders/glow.tshader" , scope $"{surfaceSource}\n// touched\n").IgnoreError();
			let failedAgain = ShaderCompiler.CompileProject(root, log);
			let stampAfter = File.GetLastWriteTimeUtc(scope $"{cFolder}/Shaders/Compiled/spirv/{name}_fs.bin");
			DateTime a = default, b = default;
			if (stamp case .Ok(let first))
				a = first;
			if (stampAfter case .Ok(let second))
				b = second;
			ok &= Check(failed == 0 && failedAgain == 0 && b > a, "the project's shaders are compiled when their source is newer than what was built");
		}

		// ---- shader graphs ----
		{
			let graph = scope NodeGraph();
			graph.isShader = true;
			let output = graph.AddNode(NodeLibrary.Find("shader.output"), .(600, 100));
			let tint = graph.AddNode(NodeLibrary.Find("shader.prop.color"), .(0, 0));
			let speed = graph.AddNode(NodeLibrary.Find("shader.prop.float"), .(0, 100));
			let pulse = graph.AddNode(NodeLibrary.Find("shader.pulse"), .(200, 100));
			let sample = graph.AddNode(NodeLibrary.Find("shader.prop.texture"), .(0, 200));
			let scroll = graph.AddNode(NodeLibrary.Find("shader.panner"), .(-200, 200));
			let normal = graph.AddNode(NodeLibrary.Find("shader.objectnormal"), .(200, 300));
			let push = graph.AddNode(NodeLibrary.Find("shader.vscale"), .(400, 300));
			graph.Validate();
			tint.values[0].Set("tint");
			tint.values[1].Set("1 0.5 0.25 1");
			speed.values[0].Set("speed");
			speed.values[1].Set("3");
			sample.values[0].Set("detail");
			scroll.values[1].Set("0.1 0");
			push.values[1].Set("0.05");
			graph.Connect(tint.id, 0, output.id, 0); // a colour into Albedo: cut down to its rgb
			graph.Connect(speed.id, 0, pulse.id, 0);
			graph.Connect(pulse.id, 0, output.id, 4); // a number into Emissive: fills all three
			graph.Connect(scroll.id, 0, sample.id, 1);
			graph.Connect(sample.id, 0, output.id, 3); // a colour into Roughness: its first channel
			graph.Connect(normal.id, 0, push.id, 0);
			graph.Connect(push.id, 0, output.id, 5);
			let text = scope String(), problem = scope String();
			let made = graph.CompileShader(text, problem);
			ok &= Check(made && text.Contains("property color tint = 1 0.5 0.25 1") && text.Contains("property float speed = 3.0") && text.Contains("property texture detail")
				&& text.Contains("vec4 n2 = tint;") && text.Contains("albedo = toLinear3((n2).xyz);") && text.Contains("float n4 = (0.5 + 0.5 * sin(time * n3));") && text.Contains("emissive += toLinear3(vec3_splat(n4));")
				&& text.Contains("vec4 n5 = texture2D(detail, n6);") && text.Contains("vec2 n6 = (uv + vec2(0.1, 0.0) * time);") && text.Contains("roughness = (n5).x;")
				&& text.Contains("vec3 n8 = (n7 * 0.05);") && text.Contains("position += n8;") && !text.Contains("metallic =") && text.IndexOf("vec2 n6") < text.IndexOf("vec4 n5"),
				"a shader graph becomes a shader file: properties, a local per node before what reads it, converted values, and only the outputs that are connected");
			File.WriteAllText(scope $"{cFolder}/Shaders/fromgraph.tshader" , text).IgnoreError();
			log.Clear();
			ok &= Check(ShaderCompiler.Compile(root, "Shaders/fromgraph.tshader", log), scope $"and that file compiles {log}");
			let empty = scope NodeGraph();
			empty.isShader = true;
			problem.Clear();
			ok &= Check(!empty.CompileShader(text, problem) && problem.Contains("Surface Output"), "a shader graph with no output node says what is missing");
			let script = scope NodeGraph();
			PinDef number = default, vector = default, flow = default, text2 = default;
			number.type = .Float;
			vector.type = .Vector3;
			flow.type = .Flow;
			text2.type = .String;
			ok &= Check(graph.Links(number, vector) && graph.Links(vector, number) && !graph.Links(flow, number) && !graph.Links(text2, number) && !script.Links(number, vector), "numbers, vectors and colours connect to each other in a shader graph, and only there");

			// One node read by two others is worked out once; Normal and Occlusion; custom code; several outputs.
			let shared = scope NodeGraph();
			shared.isShader = true;
			let sharedOutput = shared.AddNode(NodeLibrary.Find("shader.output"), .(600, 0));
			let noise = shared.AddNode(NodeLibrary.Find("shader.smoothnoise"), .(0, 0));
			let bumps = shared.AddNode(NodeLibrary.Find("shader.normalheight"), .(200, 0));
			let custom = shared.AddNode(NodeLibrary.Find("shader.custom.float"), .(200, 200));
			let statements = shared.AddNode(NodeLibrary.Find("shader.custom.color"), .(200, 400));
			let split = shared.AddNode(NodeLibrary.Find("shader.split"), .(400, 400));
			shared.Validate();
			ok &= Check(noise.values[1] == "8" && custom.values[0] == "a * b" && custom.values[1] == "1", "new nodes start with useful values, not zeros");
			custom.values[0].Set("a * a + b");
			statements.values[0].Set("result = c; result.g = a * 0.5;");
			shared.Connect(noise.id, 0, sharedOutput.id, 2);
			shared.Connect(noise.id, 0, sharedOutput.id, 3);
			shared.Connect(noise.id, 0, bumps.id, 0);
			shared.Connect(bumps.id, 0, sharedOutput.id, 6);
			shared.Connect(noise.id, 0, custom.id, 1);
			shared.Connect(custom.id, 0, sharedOutput.id, 7);
			shared.Connect(custom.id, 0, statements.id, 1);
			shared.Connect(statements.id, 0, split.id, 0);
			shared.Connect(split.id, 1, sharedOutput.id, 1);
			let sharedText = scope String();
			problem.Clear();
			int Occurrences(StringView text, StringView part)
			{
				int found = 0;
				for (int at = text.IndexOf(part); at >= 0; at = text.IndexOf(part, at + 1))
					found++;
				return found;
			}
			ok &= Check(shared.CompileShader(sharedText, problem) && Occurrences(sharedText, "tsg_noise(") == 1 && sharedText.Contains("metallic = n2;") && sharedText.Contains("roughness = n2;")
				&& sharedText.Contains("surfaceNormal = normalize(n3);") && sharedText.Contains("occlusion = n4;") && sharedText.Contains("result = a * a + b;")
				&& sharedText.Contains("result = c; result.g = a * 0.5;") && sharedText.Contains("alpha = n6.y;"), scope $"a node read in several places is worked out once; Normal, Occlusion, custom code and split outputs are written {problem}");
			File.WriteAllText(scope $"{cFolder}/Shaders/shared.tshader" , sharedText).IgnoreError();
			log.Clear();
			ok &= Check(ShaderCompiler.Compile(root, "Shaders/shared.tshader", log), scope $"and it compiles {log}");

			// A subgraph: a .tsgraph with Subgraph Output nodes becomes a node, written in place each time it is used.
			let sub = scope NodeGraph();
			sub.isShader = true;
			let subScale = sub.AddNode(NodeLibrary.Find("shader.sub.input.float"), .(0, 0));
			let subTint = sub.AddNode(NodeLibrary.Find("shader.sub.input.color"), .(0, 100));
			let subNoise = sub.AddNode(NodeLibrary.Find("shader.smoothnoise"), .(200, 0));
			let subMix = sub.AddNode(NodeLibrary.Find("shader.vscale"), .(200, 100));
			let subOut = sub.AddNode(NodeLibrary.Find("shader.sub.output.vector"), .(400, 0));
			let subOutNumber = sub.AddNode(NodeLibrary.Find("shader.sub.output.float"), .(400, 100));
			sub.Validate();
			subScale.values[0].Set("Scale");
			subTint.values[0].Set("Tint");
			subOut.values[0].Set("Colour");
			subOutNumber.values[0].Set("Height");
			sub.Connect(subScale.id, 0, subNoise.id, 1);
			sub.Connect(subTint.id, 0, subMix.id, 0);
			sub.Connect(subNoise.id, 0, subMix.id, 1);
			sub.Connect(subMix.id, 0, subOut.id, 1);
			sub.Connect(subNoise.id, 0, subOutNumber.id, 1);
			sub.Save(scope $"{cFolder}/Shaders/noisy.tsgraph");
			NodeLibrary.RefreshSubgraphs(cFolder);
			let subDef = NodeLibrary.Find("shsub:Shaders/noisy.tsgraph");
			ok &= Check(subDef != null && subDef.isShader && subDef.inputs.Count == 2 && subDef.inputs[0].name == "Scale" && subDef.inputs[1].type == .Color && subDef.outputs.Count == 2 && subDef.outputs[0].name == "Colour" && subDef.outputs[1].type == .Float,
				"a shader subgraph becomes a node: its inputs and outputs, named and typed");
			problem.Clear();
			let subText = scope String();
			ok &= Check(!sub.CompileShader(subText, problem) && problem.Contains("subgraph"), "a subgraph is not a shader of its own");
			if (subDef != null)
			{
				let host = scope NodeGraph();
				host.isShader = true;
				let hostOutput = host.AddNode(NodeLibrary.Find("shader.output"), .(600, 0));
				let first = host.AddNode(subDef, .(0, 0));
				let second = host.AddNode(subDef, .(0, 200));
				let hostSpeed = host.AddNode(NodeLibrary.Find("shader.prop.float"), .(-200, 0));
				host.Validate();
				hostSpeed.values[0].Set("scale");
				hostSpeed.values[1].Set("4");
				second.values[0].Set("20");
				host.Connect(hostSpeed.id, 0, first.id, 0);
				host.Connect(first.id, 0, hostOutput.id, 0);
				host.Connect(second.id, 1, hostOutput.id, 3);
				let hostText = scope String();
				problem.Clear();
				let hostMade = host.CompileShader(hostText, problem);
				ok &= Check(hostMade && Occurrences(hostText, "tsg_noise(") == 2 && hostText.Contains("float s2_n1 = n4;") && hostText.Contains("float s3_n1 = 20.0;") && hostText.Contains("vec3 n2_0 =") && hostText.Contains("float n3_1 =")
					&& hostText.Contains("albedo = toLinear3(n2_0);") && hostText.Contains("roughness = n3_1;"), scope $"a subgraph used twice is written in place twice, its inputs what reaches each node {problem}");
				File.WriteAllText(scope $"{cFolder}/Shaders/hosted.tshader" , hostText).IgnoreError();
				log.Clear();
				ok &= Check(ShaderCompiler.Compile(root, "Shaders/hosted.tshader", log), scope $"and it compiles {log}");
			}

			// Every shader node in one graph, worked out for the previews, and the preview shader compiled: each node
			// is a local the preview can show, the two vertex-only ones in the vertex block.
			let all = scope NodeGraph();
			all.isShader = true;
			let allOutput = all.AddNode(NodeLibrary.Find("shader.output"), .(0, 0));
			int count = 0;
			GraphNode objectNormal = null;
			for (let def in NodeLibrary.Defs)
			{
				if (!def.isShader || def.kind == .ShaderOutput)
					continue;
				let node = all.AddNode(def, .(0, 0));
				all.Validate();
				if (def.key.StartsWith("shader.prop."))
					node.values[0].Set(def.key == "shader.prop.float" ? "pf" : (def.key == "shader.prop.color" ? "pc" : (def.key == "shader.prop.normal" ? "pn" : "pt")));
				if (def.key == "shader.objectnormal")
					objectNormal = node;
				count++;
			}
			all.Connect(objectNormal.id, 0, allOutput.id, 5);
			let allText = scope String();
			let writer = scope ShaderGraphCode();
			let allMade = writer.Write(all, allText, true);
			File.WriteAllText(scope $"{cFolder}/Shaders/allnodes.tshader" , allText).IgnoreError();
			log.Clear();
			let allFine = allMade && ShaderCompiler.Compile(root, "Shaders/allnodes.tshader", log);
			let allLabel = scope $"all {count} shader graph nodes compile as shader code, {writer.previewSlots.Count} of them shown by the preview {writer.problems}{log}";
			ok &= Check(allFine && count > 90 && writer.previewSlots.Count > 80 && !writer.previewSlots.ContainsKey(objectNormal.id) && allText.Contains("if (u_surface.w > 0.5)") && allText.Contains("position += n"), allLabel);

			// A compute graph: what spreads from the neighbours, faded, plus a colour property where a number property
			// says; it becomes a .tcompute file.
			let flow = scope NodeGraph();
			flow.isShader = true;
			let flowOutput = flow.AddNode(NodeLibrary.Find("shader.compute.output"), .(800, 0));
			let spread = flow.AddNode(NodeLibrary.Find("shader.compute.blur"), .(0, 0));
			let fade = flow.AddNode(NodeLibrary.Find("shader.lerp"), .(200, 0));
			let amount = flow.AddNode(NodeLibrary.Find("shader.prop.float"), .(0, 200));
			let ink = flow.AddNode(NodeLibrary.Find("shader.prop.color"), .(0, 400));
			let paint = flow.AddNode(NodeLibrary.Find("shader.compute.neighbour"), .(200, 200));
			let mixed = flow.AddNode(NodeLibrary.Find("shader.vlerp"), .(400, 0));
			let spreadRgb = flow.AddNode(NodeLibrary.Find("shader.rgb"), .(200, 400));
			let inkRgb = flow.AddNode(NodeLibrary.Find("shader.rgb"), .(400, 400));
			let colour = flow.AddNode(NodeLibrary.Find("shader.makecolor"), .(600, 0));
			flow.Validate();
			amount.values[0].Set("amount");
			amount.values[1].Set("0.1");
			ink.values[0].Set("ink");
			paint.values[0].Set("1");
			flow.Connect(spread.id, 0, spreadRgb.id, 0);
			flow.Connect(ink.id, 0, inkRgb.id, 0);
			flow.Connect(spreadRgb.id, 0, mixed.id, 0);
			flow.Connect(inkRgb.id, 0, mixed.id, 1);
			flow.Connect(amount.id, 0, fade.id, 0);
			flow.Connect(paint.id, 0, fade.id, 1);
			flow.Connect(fade.id, 0, mixed.id, 2);
			flow.Connect(mixed.id, 0, colour.id, 0);
			flow.Connect(colour.id, 0, flowOutput.id, 0);
			let flowText = scope String();
			problem.Clear();
			let flowMade = flow.CompileShader(flowText, problem);
			let flowLabel = scope $"a graph ending in a Compute Output is written as a compute shader {problem}\n{flowText}";
			ok &= Check(flowMade && ShaderGraphCode.FileExtension(flow) == ".tcompute" && ShaderGraphCode.FileExtension(all) == ".tshader" && flowText.Contains("\ncompute {") && !flowText.Contains("surface {")
				&& flowText.Contains("property float amount = 0.1") && flowText.Contains("property color ink") && flowText.Contains("neighbour(1.0, 0.0)") && flowText.Contains("result = n"), flowLabel);
			File.WriteAllText(scope $"{cFolder}/Shaders/flow.tcompute" , flowText).IgnoreError();
			log.Clear();
			ok &= Check(ShaderCompiler.Compile(root, "Shaders/flow.tcompute", log), scope $"and it compiles for every backend {log}");

			// Nodes in the wrong kind of graph say so.
			let wrongCompute = flow.AddNode(NodeLibrary.Find("shader.worldpos"), .(0, 600));
			flow.Validate();
			flow.Connect(wrongCompute.id, 0, colour.id, 0);
			problem.Clear();
			ok &= Check(!flow.CompileShader(scope .(), problem) && problem.Contains("needs a surface"), scope $"a compute graph cannot read a surface's world position ({problem})");
			let wrongSurface = scope NodeGraph();
			wrongSurface.isShader = true;
			let surfaceOutput = wrongSurface.AddNode(NodeLibrary.Find("shader.output"), .(400, 0));
			let previous = wrongSurface.AddNode(NodeLibrary.Find("shader.compute.previous"), .(0, 0));
			let previousRgb = wrongSurface.AddNode(NodeLibrary.Find("shader.rgb"), .(200, 0));
			wrongSurface.Validate();
			wrongSurface.Connect(previous.id, 0, previousRgb.id, 0);
			wrongSurface.Connect(previousRgb.id, 0, surfaceOutput.id, 0);
			problem.Clear();
			ok &= Check(!wrongSurface.CompileShader(scope .(), problem) && problem.Contains("is for compute graphs"), scope $"a surface shader cannot read a compute shader's previous texture ({problem})");

			// Every node a compute graph can use, in one compute preview: a grid cell for each, compiled.
			let computeAll = scope NodeGraph();
			computeAll.isShader = true;
			computeAll.AddNode(NodeLibrary.Find("shader.compute.output"), .(0, 0));
			int computeCount = 0;
			for (let def in NodeLibrary.Defs)
			{
				if (!def.isShader || def.kind == .ShaderOutput || ShaderGraphCode.SurfaceOnly(def.key))
					continue;
				let node = computeAll.AddNode(def, .(0, 0));
				computeAll.Validate();
				if (def.key.StartsWith("shader.prop."))
					node.values[0].Set(def.key == "shader.prop.float" ? "pf" : "pc");
				// Subgraph Outputs have no value of their own to show.
				if (!def.outputs.IsEmpty)
					computeCount++;
			}
			let computeText = scope String();
			let computeWriter = scope ShaderGraphCode();
			let computeMade = computeWriter.Write(computeAll, computeText, true);
			File.WriteAllText(scope $"{cFolder}/Shaders/allcompute.tcompute" , computeText).IgnoreError();
			log.Clear();
			let computeFine = computeMade && ShaderCompiler.Compile(root, "Shaders/allcompute.tcompute", log);
			let computeLabel = scope $"all {computeCount} nodes with a value a compute graph can use compile in its preview, {computeWriter.previewSlots.Count} cells {computeWriter.problems}{log}";
			ok &= Check(computeFine && computeWriter.isCompute && computeCount > 70 && computeWriter.previewSlots.Count == computeCount && computeText.Contains("int tsgSlot"), computeLabel);
		}

		// ---- previews ----
		{
			let visual = scope String();
			AssetPreviews.VisualOnly("object 1 parent 0 active 1 name \"Car\"\ntransform 0 0 0 0 0 0 1 1 1 1\ncomponent Tallow.Rigidbody enabled 1\nfield mass 5\ncomponent Tallow.MeshRenderer enabled 1\nfield mesh \"builtin:cube\"\ncomponent Game.Engine enabled 1\nfield power 3\nobject 2 parent 1 active 1 name \"Wheel\"\ntransform 1 0 0 0 0 0 1 1 1 1\ncomponent Tallow.NetworkIdentity enabled 1\n", visual);
			ok &= Check(visual.Contains("name \"Car\"") && visual.Contains("name \"Wheel\"") && visual.Contains("Tallow.MeshRenderer") && visual.Contains("field mesh") && !visual.Contains("Rigidbody") && !visual.Contains("field mass") && !visual.Contains("Game.Engine") && !visual.Contains("power") && !visual.Contains("NetworkIdentity")
				&& AssetPreviews.Wants("a.tmat") && AssetPreviews.Wants("b.tprefab") && AssetPreviews.Wants("c.glb") && AssetPreviews.Wants("d.tsgraph") && !AssetPreviews.Wants("e.bf"), "a prefab's preview keeps what can be seen and leaves its scripts, physics and networking out");
		}

		// ---- on a Mesh Renderer ----
		{
			let scene = scope Scene();
			let one = scene.CreateGameObject("One").AddComponent<MeshRenderer>();
			let two = scene.CreateGameObject("Two").AddComponent<MeshRenderer>();
			let plain = scene.CreateGameObject("Plain").AddComponent<MeshRenderer>();
			one.material.Set("Materials/saved.tmat");
			two.material.Set("Materials/saved.tmat");
			ok &= Check(one.SharedMaterial != null && one.SharedMaterial == two.SharedMaterial && one.ActiveMaterial == two.ActiveMaterial && plain.SharedMaterial == null && plain.ActiveMaterial == null && plain.Material == null, "renderers naming one material share it; a renderer with none draws with its own fields as before");
			one.SetMaterialColor("color", .(0, 1, 0, 1));
			one.SetMaterialFloat("speed", 12);
			one.SetMaterialFloat("roughness", 0.9f);
			ok &= Check(one.ActiveMaterial != two.ActiveMaterial && one.Material.color.g == 1 && one.Material.color.r == 0 && one.Material.GetFloat("speed") == 12 && one.Material.roughness == 0.9f && two.ActiveMaterial.color.r == 0.9f && two.ActiveMaterial.GetFloat("speed") == 3, "changing one object's material gives it its own copy and leaves the other alone");
			Material.Create("Materials/other.tmat").color = .(0.1f, 0.1f, 0.1f, 1);
			one.SetMaterial("Materials/other.tmat");
			ok &= Check(one.ActiveMaterial == Material.Load("Materials/other.tmat") && one.ActiveMaterial.color.r == 0.1f, "an object can be given another material, which drops its own copy of the old one");
			plain.SetMaterialFloat("speed", 3);
			ok &= Check(plain.ActiveMaterial == null, "setting a material value on a renderer with no material does nothing");
		}
		Directory.DelTree(cFolder).IgnoreError();
		Scene.Active = null;
		return ok ? 0 : 1;
	}
}
