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

		private bool apply_player_leds(bool warn) {
			try {
				for (uint led = 1; led <= 4; led++) {
					dev.set_led(led, led == player);
				}
				print("Wiimote %s is player %u\n", format_mac(mac), player);
				return true;
			} catch (IOError e) {
				if (warn)
					warning("Failed to set player LEDs of wiimote %s: %s", format_mac(mac), e.message);
				return false;
			}
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
					dev.open(CORE);
				} catch(IOError e) {
					warning("Failed to open buttons interface: %s\n", e.message);
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
					btn = OPTIONS;
					break;
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
		 */
		private const int64 BATTERY_REFRESH_US = 30 * 1000000;
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
