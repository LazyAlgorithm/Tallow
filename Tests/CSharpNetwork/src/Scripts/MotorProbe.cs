using System.Numerics;
using Tallow;

namespace NetGame;

/// A C# motor with state of its own (a charge counter) kept through client prediction by the prediction state hooks.
/// The server bumps the charge once; the client never does, so it can only learn it from a rollback that restores
/// the server's state.
public class MotorProbe : Script
{
    private const int Bump = 100;
    private int _charge;
    private int _runs;
    private bool _bumped;
    private int _captures, _prepares, _restores;
    public bool Done;

    public override void Update(TickInput input, float deltaTime)
    {
        if (!Scene.IsNetworked || GameObject.OwnerClientId <= 0)
            return;
        _charge++;
        _runs++;
        Transform.Position += new Vector3(0.01f, 0, 0);
        if (Scene.IsServer && !_bumped && _charge >= 60)
        {
            _bumped = true;
            _charge += Bump;
            Transform.Position += new Vector3(1, 0, 0);
        }
    }

    public override void CapturePredictionState(ref PredictionState state)
    {
        _captures++;
        state.Extra0.X = _charge;
    }

    public override void PreparePredictionState(in PredictionState state) => _prepares++;

    public override void RestorePredictionState(in PredictionState state)
    {
        _restores++;
        _charge = (int)state.Extra0.X;
    }

    public override void FixedUpdate(float deltaTime)
    {
        if (Done || !Scene.IsClient || !IsMine)
            return;
        if (_charge > Bump && _restores > 0)
        {
            Done = true;
            SyncProbe.Check($"C# prediction hooks: a rollback restores a motor's own state from the server " +
                $"(charge {_charge}, captures {_captures}, prepares {_prepares}, restores {_restores})",
                _captures > 0 && _prepares > 0);
        }
        else if (_runs > 60 * 15)
        {
            Done = true;
            Log.Error($"NETTEST FAIL the server's motor state never reached the client (charge {_charge}, " +
                $"captures {_captures}, restores {_restores})");
        }
    }
}
