using System;
using UnityEngine;

namespace Sim.Controllers {
    /// <summary>
    /// Optional per-axis command delay for the PWM path. The PWM node publishes only the four
    /// post-mixer thruster commands, so they are projected onto the orthogonal modes of the
    /// boat's mixer (rows FL, FR, RR, RL; columns surge, sway, yaw; the fourth, common mode is
    /// zero for any mixer output), each mode is delayed by its own number of physics ticks, and
    /// the result is recomposed and clamped to +/-maxCommand like the normal path (recomposing
    /// delayed axes can exceed it; the clamp is a nonlinearity only in saturation). Inputs and
    /// outputs are indexed by thruster POSITION (FL, FR, RR, RL), never by physical output. Surge, sway and yaw therefore reach the thrusters with their own
    /// delay and no axis leaks into another. The common mode is not an axis and is not delayed.
    /// Default OFF: the controller only creates this object when a preset or delays are given.
    /// </summary>
    public sealed class AxisCommandDelay {
        public const string PresetRoboBoat1018 = "roboboat_1018_axis_delay";

        /// <summary>PREPLAY-derived (single day, 2026-10-18): surge 0.59 s, sway 0.58 s, yaw 0.19 s.</summary>
        public static bool TryPreset(string name, out float surge, out float sway, out float yaw) {
            surge = sway = yaw = 0f;
            if (name != PresetRoboBoat1018) return false;
            surge = 0.59f; sway = 0.58f; yaw = 0.19f;
            return true;
        }

        public static int Ticks(float seconds, float dt) =>
            seconds <= 0f ? 0 : (int)Math.Round(seconds / dt, MidpointRounding.AwayFromZero);

        // Mode matrix derived from the simulator's own mixer: column a = thruster vector (position
        // order FL, FR, RR, RL, unit effort) for a unit ROS-frame surge / sway / yaw command pushed
        // through ROSOmniXCommand.ToControllerMotion and OmniXController.Mix. Columns are orthogonal.
        private static readonly float[,] Mix = BuildMix();

        private static float[,] BuildMix() {
            var m = new float[4, 3];
            var c = new float[4];
            for (int a = 0; a < 3; a++) {
                ROSOmniXCommand.ToControllerMotion(a == 0 ? 1f : 0f, a == 1 ? 1f : 0f,
                    a == 2 ? 1f : 0f, out Vector3 lin, out Vector3 ang);
                OmniXController.Mix(lin, ang, 1f, c);
                for (int o = 0; o < 4; o++) m[o, a] = c[o];
            }
            return m;
        }

        private readonly int[] ticks;
        private readonly float[][] ring;
        private readonly int[] head = new int[3];
        public bool Active { get; }

        private readonly float maxCommand;

        public AxisCommandDelay(float surgeS, float swayS, float yawS, float dt,
            float maxCommand = float.PositiveInfinity) {
            this.maxCommand = maxCommand;
            ticks = new[] { Ticks(surgeS, dt), Ticks(swayS, dt), Ticks(yawS, dt) };
            Active = ticks[0] > 0 || ticks[1] > 0 || ticks[2] > 0;
            ring = new float[3][];
            for (int a = 0; a < 3; a++) ring[a] = new float[ticks[a] + 1];
        }

        public int TicksOf(int axis) => ticks[axis];

        public void Reset() {
            for (int a = 0; a < 3; a++) {
                Array.Clear(ring[a], 0, ring[a].Length);
                head[a] = 0;
            }
        }

        /// <summary>One physics tick: thruster commands in, delayed thruster commands out.</summary>
        public void Step(float[] input, float[] output) {
            if (!Active) {
                Array.Copy(input, output, 4);
                return;
            }
            // Mixer columns are orthogonal with norm^2 = 4.
            float common = 0.25f * (input[0] + input[1] + input[2] + input[3]);
            Span<float> axis = stackalloc float[3];
            for (int a = 0; a < 3; a++) {
                float m = 0.25f * (Mix[0, a] * input[0] + Mix[1, a] * input[1] +
                                   Mix[2, a] * input[2] + Mix[3, a] * input[3]);
                float[] r = ring[a];
                r[head[a]] = m;
                head[a] = (head[a] + 1) % r.Length;
                axis[a] = r[head[a]]; // oldest sample: the input from ticks[a] steps ago
            }
            for (int o = 0; o < 4; o++)
                output[o] = Mathf.Clamp(Mix[o, 0] * axis[0] + Mix[o, 1] * axis[1] +
                                        Mix[o, 2] * axis[2] + common, -maxCommand, maxCommand);
        }
    }
}
