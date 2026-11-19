using UnityEngine;
using Sim.Actuators.Motors;
using UnityEngine.InputSystem;

namespace Sim.Controllers {
    public class OmniXController : MonoBehaviour, IControllerBase {
        [SerializeField] private InputActionReference linearAction, angularAction;
        private Vector2 linearInput;
        private float angularInput;
        public ThrusterConfig config; // Assumes all thrusters have this configuration
        public Thruster frontLeft, frontRight, rearLeft, rearRight;
        public bool movementOverride = false;

        private void OnEnable() {
            linearAction.action.performed += OnLinearPerformed;
            linearAction.action.canceled += OnLinearCanceled;

            angularAction.action.performed += OnAngularPerformed;
            angularAction.action.canceled += OnAngularCanceled;

            linearAction.action.Enable();
            angularAction.action.Enable();
        }

        private void OnDisable() {
            linearAction.action.performed -= OnLinearPerformed;
            linearAction.action.canceled -= OnLinearCanceled;

            angularAction.action.performed -= OnAngularPerformed;
            angularAction.action.canceled -= OnAngularCanceled;

            linearAction.action.Disable();
            angularAction.action.Disable();
        }

        private void OnLinearPerformed(InputAction.CallbackContext ctx) {
            movementOverride = true;
            linearInput = ctx.ReadValue<Vector2>();
            Move();
        }

        private void OnLinearCanceled(InputAction.CallbackContext ctx) {
            movementOverride = false;
            linearInput = Vector2.zero;
            Move();
        }

        private void OnAngularPerformed(InputAction.CallbackContext ctx) {
            movementOverride = true;
            angularInput = ctx.ReadValue<float>();
            Move();
        }

        private void OnAngularCanceled(InputAction.CallbackContext ctx) {
            movementOverride = false;
            angularInput = 0;
            Move();
        }

        private void Move() {
            SetMotion(new Vector3(linearInput.x, linearInput.y, 0), new Vector3(0, 0, angularInput));
        }

        // TODO: More accurately model desired linear and angular velocity (not just full forward throttle/backward/angular)
        public void SetMotion(Vector3 linear, Vector3 angular) {
            float[] c = new float[4];
            Mix(linear, angular, config.GetMaxCommand(), c);
            frontLeft.SetCommand(c[0]);
            frontRight.SetCommand(c[1]);
            rearRight.SetCommand(c[2]);
            rearLeft.SetCommand(c[3]);
        }

        /// <summary>
        /// The mixer behind <see cref="SetMotion"/> as a pure function; result order is thruster
        /// position FL, FR, RR, RL. Combines translation and yaw before saturation: the previous
        /// mutually exclusive branches discarded Nav2 forward velocity whenever angular.z was
        /// non-zero, making curved paths impossible.
        /// </summary>
        public static void Mix(Vector3 linear, Vector3 angular, float maximum, float[] result) {
            float x = linear.x;
            float y = linear.y;
            float yaw = angular.z;
            float fl = -x - y - yaw;
            float fr = x - y + yaw;
            float rl = -x + y + yaw;
            float rr = x + y - yaw;
            float peak = Mathf.Max(1f, Mathf.Abs(fl), Mathf.Abs(fr), Mathf.Abs(rl),
                Mathf.Abs(rr));
            float scale = maximum / peak;
            result[0] = fl * scale;
            result[1] = fr * scale;
            result[2] = rr * scale;
            result[3] = rl * scale;
        }
    }
}
