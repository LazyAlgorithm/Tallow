namespace Tallow;

/// <summary>
/// The scene's environment: sky, ambient light, fog, bloom, ambient occlusion, depth of field, motion blur and colour
/// grading, as set in the scene's Environment settings. Change it while playing (<c>Scene.Environment.Saturation = 0.5f</c>);
/// the scene file keeps what the editor set. <see cref="ScreenEffects"/> holds the player's own choices on top.
/// </summary>
public readonly record struct SceneEnvironment(ulong SessionId)
{
    /// <summary>The sky's colour straight up.</summary>
    public Color SkyZenith
    {
        get => Color(0);
        set => Set(0, value.R, value.G, value.B, value.A);
    }
    /// <summary>The sky's colour at the horizon.</summary>
    public Color SkyHorizon
    {
        get => Color(1);
        set => Set(1, value.R, value.G, value.B, value.A);
    }
    /// <summary>The colour below the horizon, where there is no ground to see.</summary>
    public Color SkyGround
    {
        get => Color(2);
        set => Set(2, value.R, value.G, value.B, value.A);
    }
    /// <summary>The light from the sky on surfaces facing up, on top of the lights.</summary>
    public Color AmbientSky
    {
        get => Color(3);
        set => Set(3, value.R, value.G, value.B, value.A);
    }
    /// <summary>The light from below on surfaces facing down.</summary>
    public Color AmbientGround
    {
        get => Color(4);
        set => Set(4, value.R, value.G, value.B, value.A);
    }
    /// <summary>How strong the ambient light is.</summary>
    public float AmbientIntensity
    {
        get => Float(5);
        set => Set(5, value, 0, 0, 0);
    }
    /// <summary>The colour things fade to in the distance.</summary>
    public Color FogColor
    {
        get => Color(6);
        set => Set(6, value.R, value.G, value.B, value.A);
    }
    /// <summary>How thick the fog is: about how much of the view it takes per metre. 0 is no fog.</summary>
    public float FogDensity
    {
        get => Float(7);
        set => Set(7, value, 0, 0, 0);
    }
    /// <summary>How bright the whole picture is: 1 is as lit, above 1 brighter.</summary>
    public float Exposure
    {
        get => Float(8);
        set => Set(8, value, 0, 0, 0);
    }
    /// <summary>Glow around bright things. 0 is off; 0.3 to 0.6 is gentle; above 1 is heavy.</summary>
    public float Bloom
    {
        get => Float(9);
        set => Set(9, value, 0, 0, 0);
    }
    /// <summary>How bright something must be before it glows (1: only emissive and over-bright things).</summary>
    public float BloomThreshold
    {
        get => Float(10);
        set => Set(10, value, 0, 0, 0);
    }
    /// <summary>How far from the camera the sun's shadows are drawn, in metres. Shorter is sharper.</summary>
    public float ShadowDistance
    {
        get => Float(11);
        set => Set(11, value, 0, 0, 0);
    }
    /// <summary>How strongly surfaces mirror the sky and the reflection probes: 1 as they are, 0 none.</summary>
    public float ReflectionIntensity
    {
        get => Float(12);
        set => Set(12, value, 0, 0, 0);
    }
    /// <summary>Darkens creases, corners and where things meet the ground. 0 is off; 1 is normal; up to 2.</summary>
    public float AmbientOcclusion
    {
        get => Float(13);
        set => Set(13, value, 0, 0, 0);
    }
    /// <summary>How far around each point, in metres, ambient occlusion looks.</summary>
    public float OcclusionRadius
    {
        get => Float(14);
        set => Set(14, value, 0, 0, 0);
    }
    /// <summary>Blurs what is nearer or further than the focus. 0 is off; 1 the largest blur; up to 2.</summary>
    public float DepthOfField
    {
        get => Float(15);
        set => Set(15, value, 0, 0, 0);
    }
    /// <summary>The distance, in metres from the camera, that is sharp.</summary>
    public float FocusDistance
    {
        get => Float(16);
        set => Set(16, value, 0, 0, 0);
    }
    /// <summary>How deep the sharp band around the focus is, in metres.</summary>
    public float FocusRange
    {
        get => Float(17);
        set => Set(17, value, 0, 0, 0);
    }
    /// <summary>Focus on whatever is in the middle of the screen instead of FocusDistance.</summary>
    public bool AutoFocus
    {
        get => Float(18) != 0;
        set => Set(18, value ? 1 : 0, 0, 0, 0);
    }
    /// <summary>Camera motion blur. 0 is off; 0.5 is like a film camera; 1 is the whole movement of a frame.</summary>
    public float MotionBlur
    {
        get => Float(19);
        set => Set(19, value, 0, 0, 0);
    }
    /// <summary>Colour grading contrast: 1 leaves the picture alone.</summary>
    public float Contrast
    {
        get => Float(20);
        set => Set(20, value, 0, 0, 0);
    }
    /// <summary>How strong colours are: 0 is grey, 1 as they are, above 1 stronger.</summary>
    public float Saturation
    {
        get => Float(21);
        set => Set(21, value, 0, 0, 0);
    }
    /// <summary>White balance: above 0 warmer, below 0 cooler. -1 to 1.</summary>
    public float Temperature
    {
        get => Float(22);
        set => Set(22, value, 0, 0, 0);
    }
    /// <summary>Above 0 towards magenta, below 0 towards green. -1 to 1.</summary>
    public float Tint
    {
        get => Float(23);
        set => Set(23, value, 0, 0, 0);
    }
    /// <summary>Multiplies the light of the whole picture: a coloured filter on the lens.</summary>
    public Color ColorFilter
    {
        get => Color(24);
        set => Set(24, value.R, value.G, value.B, value.A);
    }
    /// <summary>Darkening towards the corners.</summary>
    public float Vignette
    {
        get => Float(25);
        set => Set(25, value, 0, 0, 0);
    }
    /// <summary>How much of the colour lookup table is used: 0 none, 1 all of it.</summary>
    public float ColorLookupStrength
    {
        get => Float(26);
        set => Set(26, value, 0, 0, 0);
    }
    /// <summary>How strong the light bounced between surfaces is: 0 off, 1 normal, up to 4. The player picks how it is
    /// worked out, or turns it off, with <see cref="ScreenEffects.GlobalIllumination"/>.</summary>
    public float GlobalIllumination
    {
        get => Float(27);
        set => Set(27, value, 0, 0, 0);
    }
    /// <summary>What the sky is drawn from: three colours, the physical sky that follows the sun, or a skybox picture
    /// (<see cref="Skybox"/>).</summary>
    public SkyMode SkyMode
    {
        get => (SkyMode)(int)Float(28);
        set => Set(28, (int)value, 0, 0, 0);
    }
    /// <summary>The skybox drawn when <see cref="SkyMode"/> is <see cref="Tallow.SkyMode.Custom"/>: a project path to a
    /// 2:1 panorama (.hdr, .exr, .png, .jpg), a cubemap (.ktx, .dds) or a folder of six faces named px/nx/py/ny/pz/nz or
    /// right/left/up/down/front/back. Empty for none (the physical sky is drawn). It is loaded when first drawn.</summary>
    public string Skybox
    {
        get
        {
            ulong session = SessionId;
            return ActionText.Read(buffer => CSharpEnvironment.GetSkybox(session, buffer)) ?? "";
        }
        set
        {
            if (!CSharpEnvironment.SetSkybox(SessionId, value ?? ""))
                throw new InvalidOperationException("The scene's environment cannot be changed (no scene).");
        }
    }
    /// <summary>How far the skybox is turned round the vertical axis, in degrees (clockwise seen from above).</summary>
    public float SkyboxRotation
    {
        get => Float(29);
        set => Set(29, value, 0, 0, 0);
    }
    /// <summary>The skybox's brightness in stops (EV): +1 twice as bright, -1 half.</summary>
    public float SkyboxExposure
    {
        get => Float(30);
        set => Set(30, value, 0, 0, 0);
    }
    /// <summary>A colour the skybox is multiplied by (white: as it is).</summary>
    public Color SkyboxTint
    {
        get => Color(31);
        set => Set(31, value.R, value.G, value.B, value.A);
    }
    /// <summary>How much of the physical sky (with its sun, moon and stars) shows under the skybox: 0 the skybox
    /// replaces it, above 0 the physical sky is drawn under it and added to it.</summary>
    public float SkyboxBlend
    {
        get => Float(32);
        set => Set(32, value, 0, 0, 0);
    }
    /// <summary>Volumetric fog: fog lit by the sun, with light shafts where shadows cut it, by the scene's point and
    /// spot lights, and by Fog Volumes. Off, the scene keeps its plain distance fog (<see cref="FogDensity"/>). Needs
    /// Vulkan, Direct3D or Metal; OpenGL and the web draw a cheaper height fog with sun shafts instead. The graphics
    /// quality setting can also turn it off (Low).</summary>
    public bool VolumetricFog
    {
        get => Float(33) != 0;
        set => Set(33, value ? 1 : 0, 0, 0, 0);
    }
    /// <summary>How thick the volumetric fog is at and below <see cref="FogHeight"/>, per metre (0.02 fades out over
    /// about 50 m). 0 leaves only Fog Volumes.</summary>
    public float VolumetricDensity
    {
        get => Float(34);
        set => Set(34, value, 0, 0, 0);
    }
    /// <summary>The height, in metres (world space), the volumetric fog starts to thin out above.</summary>
    public float FogHeight
    {
        get => Float(35);
        set => Set(35, value, 0, 0, 0);
    }
    /// <summary>How fast the volumetric fog thins above <see cref="FogHeight"/>, per metre (0: the same everywhere).</summary>
    public float FogFalloff
    {
        get => Float(36);
        set => Set(36, value, 0, 0, 0);
    }
    /// <summary>How much light goes on forward through the volumetric fog: -0.9 to 0.9. Higher makes a bright glow
    /// round the sun when looking towards it; 0 scatters every way the same.</summary>
    public float FogAnisotropy
    {
        get => Float(37);
        set => Set(37, value, 0, 0, 0);
    }
    /// <summary>The volumetric fog's colour: what share of each colour of light it scatters back (white leaves light as
    /// it is).</summary>
    public Color FogAlbedo
    {
        get => Color(38);
        set => Set(38, value.R, value.G, value.B, value.A);
    }
    /// <summary>How much sunlight the volumetric fog scatters: 1 as it should, more for stronger light shafts.</summary>
    public float SunScattering
    {
        get => Float(39);
        set => Set(39, value, 0, 0, 0);
    }
    /// <summary>How much of the ambient (sky) light the volumetric fog scatters.</summary>
    public float VolumetricAmbient
    {
        get => Float(40);
        set => Set(40, value, 0, 0, 0);
    }
    /// <summary>How far the volumetric fog's grid reaches, in metres: beyond it the fog goes on as plain height fog.</summary>
    public float FogDistance
    {
        get => Float(41);
        set => Set(41, value, 0, 0, 0);
    }

    private float Float(int which)
    {
        Span<float> values = stackalloc float[4];
        return CSharpEnvironment.Get(SessionId, which, values) ? values[0] : 0;
    }

    private Color Color(int which)
    {
        Span<float> values = stackalloc float[4];
        return CSharpEnvironment.Get(SessionId, which, values) ? new Color(values[0], values[1], values[2], values[3]) : default;
    }

    private void Set(int which, float x, float y, float z, float w)
    {
        if (!CSharpEnvironment.Set(SessionId, which, x, y, z, w))
            throw new InvalidOperationException("The scene's environment cannot be changed (no scene, or a number that is not finite).");
    }
}

public readonly partial record struct Scene
{
    /// <summary>The scene's sky, light, fog and screen effects.</summary>
    public SceneEnvironment Environment => new(SessionId);
}

/// <summary>What the sky is drawn from (<see cref="SceneEnvironment.SkyMode"/>).</summary>
public enum SkyMode
{
    /// <summary>Three colours: zenith, horizon and ground.</summary>
    Gradient,
    /// <summary>The air lit by the sun: blue by day, red at sunset, stars and the moon at night.</summary>
    Physical,
    /// <summary>A skybox picture (<see cref="SceneEnvironment.Skybox"/>).</summary>
    Custom,
}

/// <summary>How light bounced off surfaces onto others (global illumination) is worked out, cheapest first. Each
/// quality preset picks one: Very Low Ambient, Low Baked, Medium ScreenSpace, High ProbeGrid, Ultra
/// ProbeGridAndScreenSpace.</summary>
public enum GlobalIlluminationMode
{
    /// <summary>The scene's flat ambient light only; baked lightmaps and light probes are not used.</summary>
    Ambient,
    /// <summary>Baked global illumination (lightmaps and light probes) only.</summary>
    Baked,
    /// <summary>Baked plus half-resolution screen-space GI (SSGI).</summary>
    ScreenSpace,
    /// <summary>Dynamic GI: a probe grid round the camera traces rays into the scene. Sees off-screen light.</summary>
    ProbeGrid,
    /// <summary>Dynamic GI plus full-resolution screen-space GI.</summary>
    ProbeGridAndScreenSpace,
}

/// <summary>
/// The player's choices about the screen effects, for a settings menu: the scene decides how much ambient occlusion,
/// depth of field and motion blur it has (<see cref="SceneEnvironment"/>); these turn each off, tone motion blur down
/// and set the brightness. Keep them with the player's saved settings and set them here when they change.
/// </summary>
public static class ScreenEffects
{
    /// <summary>Ambient occlusion on or off.</summary>
    public static bool AmbientOcclusion { get => CSharpEnvironment.GetScreenEffect(0) != 0; set => CSharpEnvironment.SetScreenEffect(0, value ? 1 : 0); }
    /// <summary>Depth of field on or off.</summary>
    public static bool DepthOfField { get => CSharpEnvironment.GetScreenEffect(1) != 0; set => CSharpEnvironment.SetScreenEffect(1, value ? 1 : 0); }
    /// <summary>Motion blur on or off.</summary>
    public static bool MotionBlur { get => CSharpEnvironment.GetScreenEffect(2) != 0; set => CSharpEnvironment.SetScreenEffect(2, value ? 1 : 0); }
    /// <summary>The scene mirrored in water from the screen; off, water mirrors the sky and probes only.</summary>
    public static bool WaterReflections { get => CSharpEnvironment.GetScreenEffect(3) != 0; set => CSharpEnvironment.SetScreenEffect(3, value ? 1 : 0); }
    /// <summary>The scene mirrored in shiny surfaces from the screen; off, the sky and probes only.</summary>
    public static bool SurfaceReflections { get => CSharpEnvironment.GetScreenEffect(4) != 0; set => CSharpEnvironment.SetScreenEffect(4, value ? 1 : 0); }
    /// <summary>Scales the scene's motion blur: 0 none, 1 as the scene has it, up to 2.</summary>
    public static float MotionBlurAmount { get => CSharpEnvironment.GetScreenEffect(5); set => CSharpEnvironment.SetScreenEffect(5, value); }
    /// <summary>Multiplies the scene's exposure: the usual brightness setting, 0.25 to 4 (1 leaves it alone).</summary>
    public static float Brightness { get => CSharpEnvironment.GetScreenEffect(6); set => CSharpEnvironment.SetScreenEffect(6, value); }
    /// <summary>Global illumination (light bounced between surfaces), from flat ambient up to dynamic GI + SSGI.</summary>
    public static GlobalIlluminationMode GlobalIllumination { get => (GlobalIlluminationMode)(int)CSharpEnvironment.GetScreenEffect(7); set => CSharpEnvironment.SetScreenEffect(7, (int)value); }
    /// <summary>Everything back to the defaults.</summary>
    public static void Reset() => CSharpEnvironment.SetScreenEffect(100, 0);
}
