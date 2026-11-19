using NUnit.Framework;
using UnityEngine;
using Sim.Controllers;

namespace Sim.Tests.Editor {
    public sealed class AxisCommandDelayTests {
        private const float Max = 1f;

        // Thruster vector (FL, FR, RR, RL) for a ROS-frame command, via the real boundary + mixer.
        private static float[] Thrusters(float surge, float sway, float yaw, float max = Max) {
            ROSOmniXCommand.ToControllerMotion(surge, sway, yaw, out Vector3 lin, out Vector3 ang);
            var c = new float[4];
            OmniXController.Mix(lin, ang, max, c);
            return c;
        }

        // Axis content of a thruster vector, by projecting onto the real unit-axis vectors.
        private static (float s, float w, float y) Axes(float[] t) {
            float Proj(float[] u) {
                float d = 0f, n = 0f;
                for (int i = 0; i < 4; i++) { d += t[i] * u[i]; n += u[i] * u[i]; }
                return d / n;
            }
            return (Proj(Thrusters(1, 0, 0)), Proj(Thrusters(0, 1, 0)), Proj(Thrusters(0, 0, 1)));
        }

        [Test]
        public void OffIsBitIdentical() {
            var off = new AxisCommandDelay(0f, 0f, 0f, 0.01f);
            Assert.That(off.Active, Is.False);
            var rng = new System.Random(7);
            var o = new float[4];
            for (int k = 0; k < 500; k++) {
                var i = new float[4];
                for (int j = 0; j < 4; j++) i[j] = (float)(rng.NextDouble() * 2 - 1);
                off.Step(i, o);
                for (int j = 0; j < 4; j++)
                    Assert.That(System.BitConverter.SingleToInt32Bits(o[j]),
                        Is.EqualTo(System.BitConverter.SingleToInt32Bits(i[j])));
            }
        }

        [Test]
        public void PresetDelaysEachAxisAndDoesNotLeak() {
            Assert.That(AxisCommandDelay.TryPreset(AxisCommandDelay.PresetRoboBoat1018,
                out float s, out float w, out float y), Is.True);
            foreach (var (dt, ds, dw, dy) in new[] { (0.01f, 59, 58, 19), (0.005f, 118, 116, 38) }) {
                var d = new AxisCommandDelay(s, w, y, dt, 10f);
                Assert.That(new[] { d.TicksOf(0), d.TicksOf(1), d.TicksOf(2) }, Is.EqualTo(new[] { ds, dw, dy }));
                // Simultaneous unit steps on all three axes from tick 0; each must appear only at its own tick.
                var o = new float[4];
                var input = Thrusters(0.3f, 0.2f, 0.5f);
                for (int k = 0; k <= ds + 5; k++) {
                    d.Step(input, o);
                    var (os, ow, oy) = Axes(o);
                    Assert.That(os, Is.EqualTo(k >= ds ? 0.3f : 0f).Within(1e-6f), $"surge k={k}");
                    Assert.That(ow, Is.EqualTo(k >= dw ? 0.2f : 0f).Within(1e-6f), $"sway k={k}");
                    Assert.That(oy, Is.EqualTo(k >= dy ? 0.5f : 0f).Within(1e-6f), $"yaw k={k}");
                }
            }
        }

        [Test]
        public void YawOnlyStepLeaksNothingIntoTranslation() {
            var d = new AxisCommandDelay(0.59f, 0.58f, 0.19f, 0.01f);
            var o = new float[4];
            for (int k = 0; k < 100; k++) {
                d.Step(Thrusters(0f, 0f, 0.8f), o);
                var (s, w, y) = Axes(o);
                Assert.That(s, Is.EqualTo(0f).Within(1e-6f));
                Assert.That(w, Is.EqualTo(0f).Within(1e-6f));
                Assert.That(y, Is.EqualTo(k >= 19 ? 0.8f : 0f).Within(1e-6f));
            }
        }

        [Test]
        public void ParseAxisDelay() {
            Assert.That(ROSThrusterPwmCommandBootstrap.ParseAxisDelay(null), Is.Null);
            Assert.That(ROSThrusterPwmCommandBootstrap.ParseAxisDelay("roboboat_1018_axis_delay"),
                Is.EqualTo(new[] { 0.59f, 0.58f, 0.19f }));
            Assert.That(ROSThrusterPwmCommandBootstrap.ParseAxisDelay("0.1,0.2,0.3"),
                Is.EqualTo(new[] { 0.1f, 0.2f, 0.3f }));
            Assert.Throws<System.ArgumentException>(() => ROSThrusterPwmCommandBootstrap.ParseAxisDelay("1,2"));
        }

        [Test]
        public void RealAxesFromSimulatorMixerEachUseOwnDelay() {
            // Distinct delays; drive pure surge, sway, yaw through OmniXController's mixer.
            var cases = new[] { (0, 11), (1, 23), (2, 37) };
            foreach (var (axis, ticks) in cases) {
                var d = new AxisCommandDelay(axis == 0 ? ticks * .01f : 0f, axis == 1 ? ticks * .01f : 0f,
                    axis == 2 ? ticks * .01f : 0f, 0.01f, 10f);
                var o = new float[4];
                var cmd = Thrusters(axis == 0 ? .4f : 0f, axis == 1 ? .4f : 0f, axis == 2 ? .4f : 0f);
                for (int k = 0; k < 60; k++) {
                    d.Step(cmd, o);
                    var (s, w, y) = Axes(o);
                    float[] got = { s, w, y };
                    for (int a = 0; a < 3; a++)
                        Assert.That(got[a], Is.EqualTo(a == axis && k >= ticks ? .4f : 0f).Within(1e-6f),
                            $"driven axis {axis}, observed {a}, k={k}");
                }
            }
        }

        [Test]
        public void NonDefaultOutputMappingIsByPosition() {
            // Position FL..RL wired to outputs 3,1,4,2. Pulses built per OUTPUT from a position vector.
            int[] outputs = { 3, 1, 4, 2 };
            float[] want = Thrusters(0.3f, -0.1f, 0.2f);
            var pulses = new ushort[4];
            for (int p = 0; p < 4; p++)
                pulses[outputs[p] - 1] = (ushort)Mathf.RoundToInt(1500f + 400f * want[p]);
            var got = new float[4];
            ROSThrusterPwmCommand.DecodeByPosition(pulses, outputs, 1f, 0f, got);
            for (int p = 0; p < 4; p++) Assert.That(got[p], Is.EqualTo(want[p]).Within(1f / 400f));
        }

        [Test]
        public void RecomposeIsClampedToMax() {
            var o = new float[4];
            // Surge 1 delayed, then switch to opposite surge + sway; mixed thruster > 1 without clamp.
            var d2 = new AxisCommandDelay(0.05f, 0f, 0f, 0.01f, 1f);
            for (int k = 0; k < 10; k++) {
                d2.Step(Thrusters(k < 5 ? 1f : 0f, k < 5 ? 0f : 1f, 0f), o);
                for (int i = 0; i < 4; i++) Assert.That(Mathf.Abs(o[i]), Is.LessThanOrEqualTo(1f));
            }
            var free = new AxisCommandDelay(0.05f, 0f, 0f, 0.01f, 1000f);
            float freePeak = 0f;
            for (int k = 0; k < 10; k++) {
                free.Step(Thrusters(k < 5 ? 1f : 0f, k < 5 ? 0f : 1f, 0f), o);
                for (int i = 0; i < 4; i++) freePeak = Mathf.Max(freePeak, Mathf.Abs(o[i]));
            }
            Assert.That(freePeak, Is.GreaterThan(1f + 1e-3f), "test must exercise the clamp");
        }

        [Test]
        public void ResetClearsBuffers() {
            var d = new AxisCommandDelay(0.05f, 0.05f, 0.05f, 0.01f, 10f);
            var o = new float[4];
            for (int k = 0; k < 3; k++) d.Step(Thrusters(.5f, .5f, .5f), o);
            d.Reset();
            var zero = new float[4];
            for (int k = 0; k < 10; k++) {
                d.Step(zero, o);
                for (int i = 0; i < 4; i++) Assert.That(o[i], Is.EqualTo(0f));
            }
        }
    }
}
