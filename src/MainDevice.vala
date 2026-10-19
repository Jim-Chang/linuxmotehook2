/* MainDevice.vala
 *
 * Copyright 2022 v1993 <v19930312@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace Linuxmotehook {
	sealed class MainDevice: Object, Cemuhook.AbstractPhysicalDevice {
		private XWiimote.Device dev;
		public WiimoteConfig conf { get; private set; }
		private IOSource dev_source;

		private Cemuhook.DeviceType devtype = NO_MOTION;
		private Cemuhook.BaseData base_data = Cemuhook.BaseData() {
			buttons = 0,
			left_x = Cemuhook.STICK_NEUTRAL,
			left_y = Cemuhook.STICK_NEUTRAL,
			right_x = Cemuhook.STICK_NEUTRAL,
			right_y = Cemuhook.STICK_NEUTRAL
		};
		private uint64 motion_timestamp = 0;
		private Cemuhook.MotionData accelerometer = {0f, 0f, 0f};
		private Cemuhook.MotionData gyroscope = {0f, 0f, 0f};
		private uint64 mac = Cemuhook.MAC_UNAVAILABLE;

		private const float ACCEL_UNITS_PER_G = 102.5f;
		// hid-wiimote reports MotionPlus rates at 8192 * 9 / 440 (~167.564) units per deg/s
		// (see wiimod_mp_in_mp() in drivers/hid/hid-wiimote-modules.c)
		private const float GYRO_UNITS_PER_DEG_PER_SEC = 8192f * 9f / 440f;

		private ExtensionDevice? extension = null;

		public Cemuhook.DeviceOrientation orientation { get { return conf.orientation; } }

		construct {
			added.connect(on_added);
		}

		public MainDevice(owned XWiimote.Device _dev, owned WiimoteConfig _conf) throws Error {
			dev = (owned)_dev;
			conf = (owned)_conf;
			dev.watch(true);
			mac = xwiimote_get_mac(dev);
			dev_source = new IOSource(new IOChannel.unix_new(dev.get_fd()), IN);
			IOFunc cb = process_incoming;
			dev_source.set_callback(cb);
			dev_source.attach();

			var app_conf = new Config();
			dev.set_mp_normalization(conf.gyro_calibration[0], conf.gyro_calibration[1], conf.gyro_calibration[2], app_conf.gyro_normalization_factor);
			update_interfaces(true);
		}

		/*
		 * Player LEDs. Right after connecting, the LED files in sysfs may not be
		 * writable yet (udev fixes their permissions), so retry for a while.
		 */
		private const uint LED_RETRY_MS = 1000;
		private const int LED_MAX_RETRIES = 10;
		private uint player = 0;
		private uint led_retry_source = 0;
		private int led_retries = 0;

		public void set_player(uint new_player) {
			if (new_player == player)
				return;
			player = new_player;
			led_retries = 0;
			if (apply_player_leds(false) || led_retry_source != 0)
				return;
			led_retry_source = GLib.Timeout.add(LED_RETRY_MS, () => {
				var last_try = ++led_retries >= LED_MAX_RETRIES;
				if (apply_player_leds(last_try) || last_try) {
					led_retry_source = 0;
					return Source.REMOVE;
				}
				return Source.CONTINUE;
			});
		}

		private void write_player_leds() throws IOError {
			for (uint led = 1; led <= 4; led++) {
				dev.set_led(led, led == player);
			}
		}

		private bool apply_player_leds(bool warn) {
			try {
				write_player_leds();
				print("Wiimote %s is player %u\n", format_mac(mac), player);
				return true;
			} catch (IOError e) {
				if (warn)
					warning("Failed to set player LEDs of wiimote %s: %s", format_mac(mac), e.message);
				return false;
			}
		}

		/*
		 * Pointer mode. Long-pressing Home switches between the gyro pointer (IR camera
		 * off, as before) and the IR pointer (IR camera on); the player LED blinks and
		 * the wiimote rumbles once for gyro, twice for IR. A short Home press is sent
		 * when Home is released.
		 *
		 * In IR mode the pointer goes out in the stick fields, which a wiimote doesn't
		 * otherwise use (extensions are separate devices). Each axis is 14 bits: high 7
		 * bits in the left stick, low 7 bits in the right stick, both offset to 128-255
		 * so a client can read them from the positive stick directions alone.
		 * x: +1 = right edge, y: +1 = top edge. L3 = IR mode, R3 = pointer valid.
		 */
		private const uint HOME_LONG_PRESS_MS = 1000;
		private const uint HOME_TAP_MS = 100;
		private const uint SIGNAL_STEP_MS = 150;
		private const double IR_CENTER_X = 511.5;
		private const double IR_CENTER_Y = 383.5;
		private const double IR_HALF_WIDTH = 512.0;
		private const double IR_HALF_HEIGHT = 384.0;

		private bool ir_mode = false;
		private uint home_timer = 0;
		private uint signal_source = 0;

		private bool pointer_valid = false;
		private double pointer_x = 0;
		private double pointer_y = 0;
		// Last seen sensor bar (left dot to right dot) and its midpoint, for one-dot frames
		private bool have_bar = false;
		private double bar_dx = 0;
		private double bar_dy = 0;
		private double last_mid_x = IR_CENTER_X;
		private double last_mid_y = IR_CENTER_Y;

		private void process_home(XWiimote.EventKeyState state) {
			switch (state) {
				case DOWN:
					if (home_timer != 0)
						Source.remove(home_timer);
					home_timer = GLib.Timeout.add(HOME_LONG_PRESS_MS, () => {
						home_timer = 0;
						set_ir_mode(!ir_mode);
						return Source.REMOVE;
					});
					break;
				case UP:
					if (home_timer == 0)
						break; // long press already handled
					Source.remove(home_timer);
					home_timer = 0;
					base_data.buttons |= Cemuhook.Buttons.OPTIONS;
					GLib.Timeout.add(HOME_TAP_MS, () => {
						base_data.buttons &= ~Cemuhook.Buttons.OPTIONS;
						updated();
						return Source.REMOVE;
					});
					break;
				case AUTOREPEAT:
					break;
			}
		}

		private void set_ir_mode(bool enable) {
			try {
				if (enable)
					dev.open(IR);
				else
					dev.close(IR);
			} catch (IOError e) {
				warning("Failed to open IR interface of wiimote %s: %s", format_mac(mac), e.message);
				return;
			}
			ir_mode = enable;
			pointer_valid = false;
			have_bar = false;
			update_pointer_fields();
			updated();
			print("Wiimote %s: %s pointer\n", format_mac(mac), enable ? "IR" : "gyro");
			signal_mode(enable ? 2 : 1);
		}

		// Blink the player LED off and on (rumbling while off) `count` times
		private void signal_mode(int count) {
			if (signal_source != 0)
				Source.remove(signal_source);
			var step = 0;
			SourceFunc tick = () => {
				var off = (step % 2) == 0;
				try {
					if (player >= 1 && player <= 4)
						dev.set_led(player, !off);
					dev.rumble(off);
				} catch (IOError e) {
					debug("Mode signal failed: %s", e.message);
				}
				if (++step < count * 2)
					return Source.CONTINUE;
				signal_source = 0;
				try {
					dev.rumble(false);
					write_player_leds();
				} catch (IOError e) {
					debug("Mode signal failed: %s", e.message);
				}
				return Source.REMOVE;
			};
			tick();
			signal_source = GLib.Timeout.add(SIGNAL_STEP_MS, (owned)tick);
		}

		private void process_ir(XWiimote.Event ev) {
			double[] xs = {};
			double[] ys = {};
			for (var i = 0; i < 4; i++) {
				if (XWiimote.event_ir_is_valid(ev.abs[i])) {
					xs += ev.abs[i].x;
					ys += ev.abs[i].y;
				}
			}

			double mid_x, mid_y;
			if (xs.length >= 2) {
				// Take the two dots farthest apart as the ends of the sensor bar
				int a = 0, b = 1;
				double best = -1;
				for (var i = 0; i < xs.length; i++) {
					for (var j = i + 1; j < xs.length; j++) {
						var d = Math.pow(xs[i] - xs[j], 2) + Math.pow(ys[i] - ys[j], 2);
						if (d > best) {
							best = d;
							a = i;
							b = j;
						}
					}
				}
				if (xs[a] > xs[b]) {
					var t = a;
					a = b;
					b = t;
				}
				bar_dx = xs[b] - xs[a];
				bar_dy = ys[b] - ys[a];
				have_bar = true;
				mid_x = (xs[a] + xs[b]) / 2;
				mid_y = (ys[a] + ys[b]) / 2;
			} else if (xs.length == 1 && have_bar) {
				// The other end is one bar length away; take the side nearer the last midpoint
				var ax = xs[0] + bar_dx / 2, ay = ys[0] + bar_dy / 2;
				var bx = xs[0] - bar_dx / 2, by = ys[0] - bar_dy / 2;
				var da = Math.pow(ax - last_mid_x, 2) + Math.pow(ay - last_mid_y, 2);
				var db = Math.pow(bx - last_mid_x, 2) + Math.pow(by - last_mid_y, 2);
				mid_x = da <= db ? ax : bx;
				mid_y = da <= db ? ay : by;
			} else {
				pointer_valid = false;
				update_pointer_fields();
				return;
			}
			last_mid_x = mid_x;
			last_mid_y = mid_y;

			// Undo the wiimote's roll: rotate the midpoint about the image centre so the bar is level
			var angle = Math.atan2(bar_dy, bar_dx);
			var cx = mid_x - IR_CENTER_X;
			var cy = mid_y - IR_CENTER_Y;
			var rx = cx * Math.cos(-angle) - cy * Math.sin(-angle);
			var ry = cx * Math.sin(-angle) + cy * Math.cos(-angle);

			// Pointing right moves the sensor bar towards smaller x in the image,
			// pointing down towards larger y (measured with a third-party remote)
			pointer_x = (-rx / IR_HALF_WIDTH).clamp(-1, 1);
			pointer_y = (-ry / IR_HALF_HEIGHT).clamp(-1, 1);
			pointer_valid = true;
			update_pointer_fields();
		}

		private void update_pointer_fields() {
			if (ir_mode)
				base_data.buttons |= Cemuhook.Buttons.L3;
			else
				base_data.buttons &= ~Cemuhook.Buttons.L3;

			if (ir_mode && pointer_valid) {
				base_data.buttons |= Cemuhook.Buttons.R3;
				encode_pointer_axis(pointer_x, out base_data.left_x, out base_data.right_x);
				encode_pointer_axis(pointer_y, out base_data.left_y, out base_data.right_y);
			} else {
				base_data.buttons &= ~Cemuhook.Buttons.R3;
				base_data.left_x = Cemuhook.STICK_NEUTRAL;
				base_data.left_y = Cemuhook.STICK_NEUTRAL;
				base_data.right_x = Cemuhook.STICK_NEUTRAL;
				base_data.right_y = Cemuhook.STICK_NEUTRAL;
			}
		}

		private static void encode_pointer_axis(double v, out uint8 high, out uint8 low) {
			var code = (int)Math.round((v + 1) / 2 * 16383);
			high = (uint8)(128 + (code >> 7));
			low = (uint8)(128 + (code & 127));
		}

		~MainDevice() {
			debug("In MainDevice destructor");
			if (dev_source != null)
				dev_source.destroy();
		}

		private void update_interfaces(bool initial_call = false) throws IOError {
			var available = dev.available();
			var opened = dev.opened();
			var unopened = available & ~opened;
			// Warn if some interfaces are opened yet not available
			warn_if_fail(unopened == (available ^ opened));

			// WiiMote's own interfaces

			if (CORE in unopened && conf.send_buttons) {
				try {
					info("Opening core interface");
					// Writable so that rumble works (used for the pointer mode signal)
					dev.open(CORE | WRITABLE);
				} catch(IOError e) {
					try {
						dev.open(CORE);
						warning("Core interface opened read-only (no rumble): %s\n", e.message);
					} catch(IOError e2) {
						warning("Failed to open buttons interface: %s\n", e2.message);
					}
				}
			} else if (PRO_CONTROLLER in unopened && conf.send_buttons) {
				// Pro controller is a separate device rather than extension, so handle it here
				try {
					info("Opening pro controller interface");
					dev.open(PRO_CONTROLLER);
				} catch(IOError e) {
					warning("Failed to open pro controller's interface: %s\n", e.message);
				}
			}

			/*if (IR in unopened && conf.send_ir) {
				try {
					info("Opening IR interface");
					dev.open(IR);
				} catch(IOError e) {
					warning("Failed to open IR interface: %s\n", e.message);
				}
			}*/

			if (ACCEL in unopened) {
				try {
					info("Opening accelerometer interface");
					dev.open(ACCEL);
				} catch(IOError e) {
					warning("Failed to open accelerometer interface (motion won't work!): %s\n", e.message);
				}
			}

			if (MOTION_PLUS in unopened) {
				try {
					info("Opening motion plus interface");
					dev.open(MOTION_PLUS);
				} catch(IOError e) {
					// Don't show warning here - it might happen for external MPs
				}
			}

			update_motion_status(dev.opened());

			// Clear unavailable interfaces
			if (!((CORE | PRO_CONTROLLER) in opened)) {
				base_data.buttons = 0;
			}

			if (!(PRO_CONTROLLER in opened)) {
				base_data.left_x = Cemuhook.STICK_NEUTRAL;
				base_data.left_y = Cemuhook.STICK_NEUTRAL;
				base_data.right_x = Cemuhook.STICK_NEUTRAL;
				base_data.right_y = Cemuhook.STICK_NEUTRAL;
			}

			if ((extension != null) && !(extension.implements_interface in opened)) {
				extension.disconnected();
				extension = null;
			}

			// Extension interfaces need some time to initialize

			if (initial_call) {
				update_external_interfaces(true);
			} else {
				GLib.Timeout.add(500, update_external_interfaces_wrapper);
			}
		}

		private bool update_external_interfaces_wrapper() { return update_external_interfaces(); }

		private bool update_external_interfaces(bool initial_call = false) {
			var available = dev.available();
			var opened = dev.opened();
			var unopened = available & ~opened;

			// Since motion plus is available as pluggable extension, check for it here as well
			if (MOTION_PLUS in unopened) {
				try {
					info("Opening motion plus interface");
					dev.open(MOTION_PLUS);
				} catch(IOError e) {
					warning("Failed to open Motion Plus interface: %s\n", e.message);
				}
			}

			update_motion_status(dev.opened());

			if (NUNCHUK in unopened) {
				try {
					info("Opening nunchuck interface");
					dev.open(NUNCHUK);
					extension = new Nunchuck(this);
				} catch(IOError e) {
					warning("Failed to open nunchuck interface: %s\n", e.message);
				}
			}

			// Extensions that have no motion are only connected if send_buttons is enabled
			if (conf.send_buttons) {
				if (CLASSIC_CONTROLLER in unopened) {
					try {
						info("Opening classic controller interface");
						dev.open(CLASSIC_CONTROLLER);
						extension = new ClassicController(this);
					} catch(IOError e) {
						warning("Failed to open classic controller interface: %s\n", e.message);
					}
				}
			}

			if ((!initial_call) && (extension != null) && (extension.implements_interface in unopened)) {
				unowned var server = new LMApplication().server;
				if (server != null) {
					try {
						server.add_device(extension);
					} catch(Cemuhook.ServerError.SERVER_FULL e) {
						print("Can't add extension to wiimote %s - server full!\n", format_mac(mac));
					} catch(Error e) {
						warning("Error adding extension to server: %s", e.message);
					}
				}
			}

			return Source.REMOVE;
		}

		private void update_motion_status(XWiimote.IfaceType opened) {
			if (ACCEL in opened) {
				if (MOTION_PLUS in opened) {
					devtype = GYRO_FULL;
				} else {
					devtype = ACCELEROMETER_ONLY;

					gyroscope = Cemuhook.MotionData() {
						x = 0f,
						y = 0f,
						z = 0f
					};
				}
			} else {
				devtype = NO_MOTION;

				accelerometer = Cemuhook.MotionData() {
					x = 0f,
					y = 0f,
					z = 0f
				};

				gyroscope = Cemuhook.MotionData() {
					x = 0f,
					y = 0f,
					z = 0f
				};
			}
		}

		public void on_added(Cemuhook.Server server) {
			try {
				if (extension != null) {
					server.add_device(extension);
				}
			} catch(Cemuhook.ServerError.ALREADY_SERVING e) {
				// This is expected
			} catch(Cemuhook.ServerError.SERVER_FULL e) {
				print("Can't add extension to wiimote %s - server full!\n", format_mac(mac));
			} catch(Error e) {
				warning("Error adding extension to server: %s", e.message);
			}
		}

		private bool process_incoming() {
			/*
			 * Sending key events instantly allows to win a little bit of latency.
			 * This can't be done with motion and sticks due to their "spammy" nature.
			 */
			try {
				bool needs_update = false;
				bool extension_needs_update = false;
				for (var? ev = dev.poll(); ev != null; ev = dev.poll()) {
					switch (ev.type) {
						case KEY:
							process_key(ev.key.code, ev.key.state);
							updated();
							needs_update = false;
							break;
						case PRO_CONTROLLER_KEY:
							process_pro_controller_key(ev.key.code, ev.key.state);
							updated();
							needs_update = false;
							break;
						case PRO_CONTROLLER_MOVE:
							process_pro_controller_movement(ev.abs[0], ev.abs[1]);
							needs_update = true;
							break;
						case ACCEL:
							motion_timestamp = ev.time_sec * 1000000 + ev.time_usec;
							process_accelerometer(ev.abs[0]);
							needs_update = true;
							break;
						case MOTION_PLUS:
							// MotionPlus delivers samples far more often than the accelerometer
							// (and the accelerometer sends nothing while values stay the same),
							// so advance the motion timestamp on gyro samples too.
							motion_timestamp = ev.time_sec * 1000000 + ev.time_usec;
							process_gyroscope(ev.abs[0]);
							needs_update = true;
							break;
						case IR:
							process_ir(ev);
							// Without MotionPlus nothing else would push the pointer out
							if (!(MOTION_PLUS in dev.opened()))
								needs_update = true;
							break;
						case NUNCHUK_KEY:
						case CLASSIC_CONTROLLER_KEY:
							extension.process_event(ev);
							extension.updated();
							extension_needs_update = false;
							break;
						case NUNCHUK_MOVE:
						case CLASSIC_CONTROLLER_MOVE:
							extension.process_event(ev);
							extension_needs_update = true;
							break;
						case WATCH:
							update_interfaces();
							needs_update = true;
							break;
						case GONE:
							destroy();
							return Source.REMOVE;
						default:
							warn_if_reached();
							break;
					}
				}

				if (needs_update) {
					updated();
				}

				if (extension_needs_update) {
					extension.updated();
				}
			} catch (Error e) {
				warning("Error when reading event: %s, disconnecting!\n", e.message);
				destroy();
			}

			return Source.CONTINUE;
		}

		private void process_key(XWiimote.EventKeyCode code, XWiimote.EventKeyState state) {
			Cemuhook.Buttons btn;
			switch (code) {
				case UP:
					btn = UP;
					break;
				case RIGHT:
					btn = RIGHT;
					break;
				case DOWN:
					btn = DOWN;
					break;
				case LEFT:
					btn = LEFT;
					break;

				case A:
					btn = A;
					break;
				case B:
					btn = B;
					break;

				case HOME:
					process_home(state);
					return;
				case MINUS:
					btn = L1;
					break;
				case PLUS:
					btn = R1;
					break;
				case ONE:
					btn = L2;
					break;
				case TWO:
					btn = R2;
					break;

				default:
					warn_if_reached();
					return;
			}

			switch (state) {
				case DOWN:
					base_data.buttons |= btn;
					break;
				case UP:
					base_data.buttons &= ~btn;
					break;
				case AUTOREPEAT:
					break;
			}
		}

		private void process_pro_controller_key(XWiimote.EventKeyCode code, XWiimote.EventKeyState state) {
			Cemuhook.Buttons btn;
			switch (code) {
				case UP:
					btn = UP;
					break;
				case RIGHT:
					btn = RIGHT;
					break;
				case DOWN:
					btn = DOWN;
					break;
				case LEFT:
					btn = LEFT;
					break;

				case A:
					btn = A;
					break;
				case B:
					btn = B;
					break;
				case X:
					btn = X;
					break;
				case Y:
					btn = Y;
					break;

				case TR:
					btn = R1;
					break;
				case TL:
					btn = L1;
					break;
				case ZR:
					btn = R2;
					break;
				case ZL:
					btn = L2;
					break;
				case THUMBL:
					btn = L3;
					break;
				case THUMBR:
					btn = R3;
					break;

				case HOME:
					btn = HOME;
					break;
				case MINUS:
					btn = SHARE;
					break;
				case PLUS:
					btn = OPTIONS;
					break;

				default:
					warn_if_reached();
					return;
			}

			switch (state) {
				case DOWN:
					base_data.buttons |= btn;
					break;
				case UP:
					base_data.buttons &= ~btn;
					break;
				case AUTOREPEAT:
					break;
			}
		}

		private void process_pro_controller_movement(XWiimote.EventAbs left, XWiimote.EventAbs right) {
			unowned var calibr = conf.pro_controller_stick_calibration;
			base_data.left_x = apply_stick_calibration(left.x, calibr[0], calibr[2]);
			base_data.left_y = apply_stick_calibration(left.y, calibr[1], calibr[3]);
			base_data.right_x = apply_stick_calibration(right.x, calibr[4], calibr[6]);
			base_data.right_y = apply_stick_calibration(right.y, calibr[5], calibr[7]);
		}

		private void process_accelerometer(XWiimote.EventAbs inp) {
			accelerometer = Cemuhook.MotionData() {
				x =  ((float)inp.x) / ACCEL_UNITS_PER_G,
				y = -((float)inp.z) / ACCEL_UNITS_PER_G,
				z = -((float)inp.y) / ACCEL_UNITS_PER_G,
			};
		}

		private void process_gyroscope(XWiimote.EventAbs inp) {
			gyroscope = Cemuhook.MotionData() {
				x = ((float)inp.z) / GYRO_UNITS_PER_DEG_PER_SEC,
				y = ((float)inp.x) / GYRO_UNITS_PER_DEG_PER_SEC,
				z = ((float)inp.y) / GYRO_UNITS_PER_DEG_PER_SEC,
			};
		}

		private void destroy() {
			if (mac != Cemuhook.MAC_UNAVAILABLE)
				print("WiiMote %s disconnected\n", format_mac(mac));

			if (extension != null) {
				extension.disconnected();
				extension = null;
			}
			disconnected();
		}

		public Cemuhook.DeviceType get_device_type() { return devtype; }
		public Cemuhook.ConnectionType get_connection_type() { return BLUETOOTH; }
		/*
		 * Reading the battery level makes hid-wiimote send a status request to the
		 * remote and wait for its reply (about 30 ms over Bluetooth). gcemuhook asks
		 * for it in every DSU packet, which blocked the main loop and capped the
		 * output at ~30 packets/s even though MotionPlus delivers ~90 samples/s.
		 * Cache the value and refresh it only every BATTERY_REFRESH_US
		 * (sooner while it is still unavailable right after connecting).
		 * Every request also takes the link out of Bluetooth sniff mode (the kernel
		 * forces active mode before sending), which a separate helper keeps the
		 * link in for steadier reports, so ask rarely.
		 */
		private const int64 BATTERY_REFRESH_US = 120 * 1000000;
		private const int64 BATTERY_RETRY_US = 2 * 1000000;
		private Cemuhook.BatteryStatus battery_status = NA;
		private int64 battery_checked_at = 0;

		public Cemuhook.BatteryStatus get_battery() {
			var now = get_monotonic_time();
			var interval = (battery_status == NA) ? BATTERY_RETRY_US : BATTERY_REFRESH_US;
			if (battery_checked_at == 0 || now - battery_checked_at >= interval) {
				battery_checked_at = now;
				battery_status = read_battery_status();
			}
			return battery_status;
		}

		private Cemuhook.BatteryStatus read_battery_status() {
			try {
				// Fully charged is about 71 (52 for rechargable batteries)
				// 4 LEDs up to about 33
				// 3 LEDs up to about 25
				// 2 LEDs up to about 16
				var capacity = dev.get_battery();
				if (capacity >= 50) {
					return FULL;
				} else if (capacity >= 35) {
					return HIGH;
				} else if (capacity >= 25) {
					return MEDIUM;
				} else if (capacity >= 15) {
					return LOW;
				} else {
					return DYING;
				}
			} catch(Error e) {
				// Commonly happens right after device's addition, so don't log error
				return NA;
			}
		}

		public uint64 get_mac() { return mac; }

		public Cemuhook.BaseData get_base_inputs() {
			return base_data;
		}

		public uint64 get_motion_timestamp() {
			return motion_timestamp;
		}

		public Cemuhook.MotionData get_accelerometer() {
			return accelerometer;
		}

		public Cemuhook.MotionData get_gyro() {
			return gyroscope;
		}
	}
}
