using System.Numerics;
using Tallow;

namespace {NAMESPACE};

/// <summary>The ordinary-script half of the courtyard crowd exhibit. Each object runs this Update.</summary>
public class CrowdWalker : Script
{
    public Vector3 Home;
    public float Phase;

    public override void Update(TickInput input, float deltaTime)
    {
        Phase += deltaTime;
        Transform.LocalPosition = Home + new Vector3(0, MathF.Sin(Phase) * 0.3f, 0);
    }
}

/// <summary>
/// Two small crowds with identical motion: blue objects each run a CrowdWalker script; orange objects are moved
/// by this one script over a packed array of their data, the system way of doing the same thing.
/// </summary>
public class GalleryCrowd : Script
{
    private struct Member
    {
        public GameObject Object;
        public Vector3 Home;
        public float Phase;
    }

    private Member[] _system = [];

    public override void Start()
    {
        var system = new List<Member>();
        for (int group = 0; group < 2; group++)
        {
            for (int i = 0; i < 36; i++)
            {
                var home = new Vector3(-5 + group * 12 + (i % 6) * 0.6f, 0.8f, -8 - (i / 6) * 0.6f);
                GameObject member = Scene.CreateGameObject(group == 0 ? "Script crowd" : "System crowd");
                member.SetParent(GameObject, false);
                member.Transform.LocalPosition = home;
                member.Transform.LocalScale = new Vector3(0.24f, 0.55f, 0.24f);
                member.AddComponent<MeshRenderer>().Color = group == 0 ? new Color(0.2f, 0.6f, 1) : new Color(1, 0.55f, 0.2f);
                if (group == 0)
                {
                    CrowdWalker walker = member.AddComponent<CrowdWalker>();
                    walker.Home = home;
                    walker.Phase = i * 0.25f;
                }
                else
                    system.Add(new Member { Object = member, Home = home, Phase = i * 0.25f });
            }
        }
        _system = [.. system];
    }

    public override void Update(TickInput input, float deltaTime)
    {
        for (int i = 0; i < _system.Length; i++)
        {
            ref Member member = ref _system[i];
            if (!member.Object.ActiveInHierarchy)
                continue;
            member.Phase += deltaTime;
            member.Object.Transform.LocalPosition = member.Home + new Vector3(0, MathF.Sin(member.Phase) * 0.3f, 0);
        }
    }

    public override void OnGUI() =>
        GUI.Label(20, GUI.Height - 36, "Courtyard crowds: blue = a script on each; orange = one script over packed data. Same motion.");
}
