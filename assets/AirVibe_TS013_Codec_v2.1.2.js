/* AirVibe — TS013 Portable Codec (v2.1.2)
   Targeting TPMfw 2.31+ | Machine Saver Inc.
   
   =============================================================================
   DESIGN DECISIONS & IMPROVEMENT LOGIC (v2.1.X)
   =============================================================================
   1. CONCERN CLUSTERING: 
      Flattened JSON is replaced with nested objects (metadata, device_settings, 
      vibration_config, alarms). This allows integrators to access entire 
      functional blocks (e.g., all velocity data) without searching 100+ keys.

   2. STABLE IDENTIFIERS: 
      Enums like push_mode, status_code or window_function now return lowercase 'slugs' 
      (e.g., "hanning") instead of numeric codes. This ensures integration 
      logic remains stable even if UI labels change.

   3. ALARM SYMMETRY: 
      Alarms are now reported as objects: { "enabled": true, "threshold": 100 }.
      This links the state of the bitmask directly to the value it controls.

   4. TEMPERATURE SCALING FIX: 
      - Type 02/07 (Reporting): 1-byte integer (1°C steps) as per TPM logic.
      - Type 04/Port 31 (Config): 2-byte value divided by 100.0 (0.01°C steps).

   5. LEGACY SUPPORT:
      - Types 1, 3, 5 (Waveform) and 17 (Missed Blocks) are preserved.
      - Ports 20, 21, 22 are preserved for advanced command/control.
   =============================================================================
*/

"use strict";

var CODEC_VERSION = "2.1.2";

// --- STABLE IDENTIFIERS (SLUGS) ---
var STATUS_ID = {
    0: "normal_operation", 1: "uart_read_error", 2: "uart_read_busy", 3: "uart_read_timeout",
    4: "uart_write_error", 5: "uart_write_busy", 6: "uart_write_timeout", 7: "modbus_crc_error",
    8: "vsm_error", 11: "timewave_api_error", 12: "timewave_timeout", 13: "timewave_bad_params",
    14: "timewave_read_error", 15: "timewave_processing_timeout", 16: "machine_off", 21: "missing_ack"
};

var PUSH_MODE_ID = { 1: "overall_only", 2: "waveform_only", 3: "overall_and_waveform" };
var WINDOW_ID    = { 0: "none", 1: "hanning", 2: "inverse_hanning", 3: "hamming", 4: "inverse_hamming" };
var AXIS_LABELS  = { 1: "axis_1", 2: "axis_2", 4: "axis_3", 7: "axis_1_2_3" };

var DL20_OP_ID   = { 0x01: "waveform_data_ack", 0x03: "waveform_info_ack" };

var CMD22_ID = {
  0x0001: "request_waveform_info",
  0x0002: "request_config",
  0x0003: "request_new_capture",
  0x0005: "init_upgrade_session",
  0x0006: "verify_upgrade_data"
};

var HW_FILTER_ID = {
    0: "none", 23: "hp_33_hz", 22: "hp_67_hz", 21: "hp_134_hz", 20: "hp_267_hz", 19: "hp_593_hz", 
    18: "hp_1335_hz", 17: "hp_2670_hz", 135: "lp_33_hz", 134: "lp_67_hz", 133: "lp_134_hz", 
    132: "lp_267_hz", 131: "lp_593_hz", 130: "lp_1335_hz", 129: "lp_2670_hz", 128: "lp_6675_hz"
};

var INVALID_AXIS_MASKS = { 3: true, 5: true, 6: true, 0: true };

// ==================== HELPERS ====================
function u8(b, i)   { return b[i] & 0xFF; }
function i8(b, i)   { var v = b[i]; return v & 0x80 ? v - 0x100 : v; }
function u16(b, i)  { return ((b[i+1] << 8) | b[i]) & 0xFFFF; }
function i16(b, i)  { var v = u16(b, i); return v & 0x8000 ? v - 0x10000 : v; }
function fw(v)      { return (v >>> 8) + "." + (v & 0xFF); }
function volt(v)    { return (v * 10 + 2000) / 1000.0; }

function hexToBytes(hex) {
  var s = String(hex || "").replace(/\s|0x/gi, "");
  if (s.length % 2) s = "0" + s;
  var out = [];
  for (var i = 0; i < s.length; i += 2) out.push(parseInt(s.substr(i, 2), 16));
  return out;
}

function validateAxisMask(mask, context, res) {
    if (INVALID_AXIS_MASKS[mask]) {
        var msg = "Invalid axis combination 0x" + mask.toString(16) + " in " + context + ". Valid: 1, 2, 4, or 7.";
        if (res.errors) res.errors.push(msg); else res.warnings.push(msg);
    }
}

// ==================== UPLINK DECODER ====================
function decodeUplink(input) {
    var res = { data: {}, warnings: [], errors: [] };
    var b = input.bytes || [];
    var port = input.fPort;
    var type = b.length > 0 ? u8(b, 0) : null;

    try {
        if (!Array.isArray(b)) throw new Error("bytes must be an array");
        
        if (port === 8) {
            // --- TYPE 4: CONFIGURATION ---
            if (type === 4) {
                var alarmMask = u16(b, 19);
                var axisMask = u8(b, 3);
                
                if (INVALID_AXIS_MASKS[axisMask]) res.warnings.push("Device reported invalid axis mask: " + axisMask);

                res.data = {
                    packet_type: 4,
                    codec_version: CODEC_VERSION,
                    metadata: { firmware_vsm: fw(u16(b, 35)), firmware_tpm: fw(u16(b, 37)), uplink_time: input.recvTime },
                    device_settings: {
                        push_mode: PUSH_MODE_ID[u8(b, 2)] || "unknown",
                        accel_range_g: u8(b, 4),
                        hw_filter: HW_FILTER_ID[u8(b, 5)] || "unknown",
                        machine_off_threshold_mg: u16(b, 39)
                    },
                    vibration_config: {
                        overall_push_period_min: u16(b, 8),
                        high_pass_filter_hz: u16(b, 12),
                        low_pass_filter_hz: u16(b, 14),
                        window_function: WINDOW_ID[u8(b, 16)] || "unknown"
                    },
                    waveform_config: {
                        push_period_min: u16(b, 6),
                        samples_per_axis: u16(b, 10),
                        active_axes: { axis_1: !!(axisMask & 1), axis_2: !!(axisMask & 2), axis_3: !!(axisMask & 4) }
                    },
                    alarms: {
                        test_period_min: u16(b, 17),
                        temperature: { enabled: !!(alarmMask & 0x01), threshold_c: i16(b, 21) / 100.0 },
                        acceleration_mg: {
                            axis_1: { enabled: !!(alarmMask & 0x02), threshold: u16(b, 23) },
                            axis_2: { enabled: !!(alarmMask & 0x04), threshold: u16(b, 25) },
                            axis_3: { enabled: !!(alarmMask & 0x08), threshold: u16(b, 27) }
                        },
                        velocity_mips: {
                            axis_1: { enabled: !!(alarmMask & 0x10), threshold: u16(b, 29) },
                            axis_2: { enabled: !!(alarmMask & 0x20), threshold: u16(b, 31) },
                            axis_3: { enabled: !!(alarmMask & 0x40), threshold: u16(b, 33) }
                        }
                    }
                };
            }
            // --- TYPE 2 & 7: OVERALL / ALARM ---
            else if (type === 2 || type === 7) {
                var rawStatus = u8(b, 1);
                var flag = u8(b, 2);
                var isOff = (rawStatus === 16);

                function val(v, mask) {
                    if (isOff) return null;
                    if (type === 7 && !(flag & mask)) return null;
                    return v;
                }

                res.data = {
                    packet_type: type,
                    status: STATUS_ID[rawStatus] || "unknown", // UPDATED
                    is_machine_off: isOff,
                    battery: { voltage_v: volt(u8(b, 4)), percent: u8(b, 5) },
                    temperature_c: val(i8(b, 3), 0x01),
                    vibration: {
                        accel_mg_rms: {
                            axis_1: val(u16(b, 6), 0x02),
                            axis_2: val(u16(b, 8), 0x04),
                            axis_3: val(u16(b, 10), 0x08)
                        },
                        velocity_mips_rms: {
                            axis_1: val(u16(b, 12), 0x10),
                            axis_2: val(u16(b, 14), 0x20),
                            axis_3: val(u16(b, 16), 0x40)
                        }
                    },
                    active_alarms: {
                        temperature: !!(flag & 0x01),
                        accel_axis_1: !!(flag & 0x02), accel_axis_2: !!(flag & 0x04), accel_axis_3: !!(flag & 0x08),
                        vel_axis_1: !!(flag & 0x10), vel_axis_2: !!(flag & 0x20), vel_axis_3: !!(flag & 0x40)
                    }
                };
            }
            // --- TYPE 3: WAVEFORM HEADER ---
            else if (type === 3) {
                var segNum = u8(b, 2);
                var axisSel = u8(b, 4);
                
                if (segNum !== 0) res.warnings.push("TWIU segmentNumber expected 0");
                if (INVALID_AXIS_MASKS[axisSel]) res.warnings.push("TWIU reports invalid axis mask: " + axisSel);

                res.data = {
                    packet_type: 3,
                    transaction_id: u8(b, 1),
                    segment_number: segNum,
                    error_code: u8(b, 3),
                    axis_selection: AXIS_LABELS[axisSel] || "unknown",
                    number_of_segments: u16(b, 5),
                    hw_filter: HW_FILTER_ID[u8(b, 7)] || "unknown",
                    sampling_rate_hz: u16(b, 8),
                    samples_per_axis: u16(b, 10)
                };
            }
            // --- TYPE 1 & 5: WAVEFORM DATA ---
            else if (type === 1 || type === 5) {
                var samples = [];
                for (var i = 4; i + 1 < b.length; i += 2) samples.push(i16(b, i));
                res.data = {
                    packet_type: type,
                    transaction_id: u8(b, 1),
                    segment_number: u16(b, 2),
                    is_last_segment: (type === 5),
                    sample_count: samples.length,
                    samples_i16: samples
                };
            }
            // --- TYPE 17: MISSED BLOCKS ---
            else if (type === 17) {
                var count = u8(b, 2);
                var missed = [];
                for (var j = 3; j + 1 < b.length && missed.length < count; j += 2) missed.push(u16(b, j));
                res.data = {
                    packet_type: 17,
                    missed_data_flag: u8(b, 1),
                    missed_block_count: count,
                    missed_blocks: missed
                };
            }
            else {
                res.errors.push("Unsupported Packet Type: " + type);
            }
        } else {
            res.errors.push("Unsupported Uplink Port: " + port);
        }
    } catch (e) { res.errors.push(e.message); }
    return res;
}

// ==================== DOWNLINK DECODE ====================
function decodeDownlink(input) {
  var res = { data: {}, warnings: [], errors: [] };
  var b = input.bytes;
  var port = input.fPort;
  
  try {
      if (port === 30) {
          if (b.length < 20) throw new Error("Port 30 too short");
          var axisMask = u8(b, 2);
          
          if (INVALID_AXIS_MASKS[axisMask]) res.warnings.push("Downlink contains invalid axis mask: " + axisMask);

          res.data = {
              f_port: 30,
              version: u8(b, 0),
              device_settings: {
                  push_mode: PUSH_MODE_ID[u8(b, 1)] || "unknown",
                  accel_range_g: u8(b, 3),
                  hw_filter: HW_FILTER_ID[u8(b, 4)] || "unknown",
                  machine_off_threshold_mg: u16(b, 18)
              },
              waveform_config: {
                  push_period_min: u16(b, 5),
                  samples_per_axis: u16(b, 9),
                  active_axes: { axis_1: !!(axisMask & 1), axis_2: !!(axisMask & 2), axis_3: !!(axisMask & 4) }
              },
              vibration_config: {
                  overall_push_period_min: u16(b, 7),
                  high_pass_filter_hz: u16(b, 11),
                  low_pass_filter_hz: u16(b, 13),
                  window_function: WINDOW_ID[u8(b, 15)] || "unknown"
              },
              alarms: { test_period_min: u16(b, 16) }
          };
      }
      else if (port === 31) {
          if (b.length < 16) throw new Error("Port 31 too short");
          var mask = u16(b, 0);
          res.data = {
              f_port: 31,
              alarms: {
                  temperature: { enabled: !!(mask & 0x01), threshold_c: u16(b, 2) / 100.0 }, 
                  acceleration_mg: {
                      axis_1: { enabled: !!(mask & 0x02), threshold: u16(b, 4) },
                      axis_2: { enabled: !!(mask & 0x04), threshold: u16(b, 6) },
                      axis_3: { enabled: !!(mask & 0x08), threshold: u16(b, 8) }
                  },
                  velocity_mips: {
                      axis_1: { enabled: !!(mask & 0x10), threshold: u16(b, 10) },
                      axis_2: { enabled: !!(mask & 0x20), threshold: u16(b, 12) },
                      axis_3: { enabled: !!(mask & 0x40), threshold: u16(b, 14) }
                  }
              }
          };
      }
      else if (port === 22) {
          if (b.length < 2) throw new Error("Port 22 too short");
          var cmd = u16(b, 0);
          var params = [];
          for (var i = 2; i < b.length; i++) params.push(u8(b, i));
          
          res.data = {
              f_port: 22,
              command_id: CMD22_ID[cmd] || "unknown", // UPDATED: Now uses Slug
              parameters: params,
              parameters_hex: params.map(function(x){ return (x < 16 ? "0" : "") + x.toString(16); }).join(" ")
          };
      }
      else if (port === 21) {
          if (b.length < 2) throw new Error("Port 21 too short");
          var mode = u8(b, 0);
          var count = u8(b, 1);
          var segments = [];
          var o = 2;
          if (mode === 0) {
              for (; o < b.length && segments.length < count; o++) segments.push(u8(b, o));
          } else {
              for (; o + 1 < b.length && segments.length < count; o += 2) segments.push(u16(b, o));
          }
          res.data = {
              f_port: 21,
              value_size_mode: mode,
              segment_count: count,
              segments: segments
          };
      }
      else if (port === 20) {
          if (b.length !== 2) throw new Error("Port 20 must be 2 bytes");
          res.data = {
              f_port: 20,
              opcode: DL20_OP_ID[u8(b, 0)] || "unknown", // UPDATED: Now uses Slug
              transaction_id: u8(b, 1)
          };
      }
      else {
          res.errors.push("Unsupported Downlink Port: " + port);
      }
  } catch (e) { res.errors.push(e.message); }
  return res;
}

// ==================== DOWNLINK ENCODER ====================
function encodeDownlink(input) {
    var res = { fPort: null, bytes: [], errors: [], warnings: [] };
    
    // Reverse Maps
    var P_VAL = { "overall_only": 1, "waveform_only": 2, "overall_and_waveform": 3 };
    var W_VAL = { "none": 0, "hanning": 1, "inverse_hanning": 2, "hamming": 3, "inverse_hamming": 4 };
    var F_VAL = { "none": 0, "hp_33_hz": 23, "hp_67_hz": 22, "hp_134_hz": 21, "hp_267_hz": 20, "hp_593_hz": 19, "hp_1335_hz": 18, "hp_2670_hz": 17, "lp_33_hz": 135, "lp_67_hz": 134, "lp_134_hz": 133, "lp_267_hz": 132, "lp_593_hz": 131, "lp_1335_hz": 130, "lp_2670_hz": 129, "lp_6675_hz": 128 };
    
    // Helper to find key by value in CMD22_ID
    function getCmdId(slug) {
        for(var k in CMD22_ID) { if(CMD22_ID[k] === slug) return parseInt(k); }
        return null;
    }
    // Helper to find key by value in DL20_OP_ID
    function getOpId(slug) {
        for(var k in DL20_OP_ID) { if(DL20_OP_ID[k] === slug) return parseInt(k); }
        return null;
    }

    try {
        if (!input.data) throw new Error("Missing 'data' property");
        var d = input.data;
        var out = [];
        var port = input.fPort || d.fPort || d.f_port;

        if (port === 30) {
            var m = d.waveform_config.active_axes;
            var axisMask = (m.axis_1 ? 1 : 0) | (m.axis_2 ? 2 : 0) | (m.axis_3 ? 4 : 0);
            
            if (INVALID_AXIS_MASKS[axisMask]) {
                throw new Error("Invalid Waveform Axis Config: " + axisMask + ". Must be single axis (1,2,4) or all three (7).");
            }

            out.push(d.version || 1);
            out.push(P_VAL[d.device_settings.push_mode] || 1);
            out.push(axisMask);
            out.push(d.device_settings.accel_range_g || 8);
            out.push(F_VAL[d.device_settings.hw_filter] || 0);
            out.push(d.waveform_config.push_period_min & 0xFF, (d.waveform_config.push_period_min >> 8) & 0xFF);
            out.push(d.vibration_config.overall_push_period_min & 0xFF, (d.vibration_config.overall_push_period_min >> 8) & 0xFF);
            out.push(d.waveform_config.samples_per_axis & 0xFF, (d.waveform_config.samples_per_axis >> 8) & 0xFF);
            out.push(d.vibration_config.high_pass_filter_hz & 0xFF, (d.vibration_config.high_pass_filter_hz >> 8) & 0xFF);
            out.push(d.vibration_config.low_pass_filter_hz & 0xFF, (d.vibration_config.low_pass_filter_hz >> 8) & 0xFF);
            out.push(W_VAL[d.vibration_config.window_function] || 0);
            out.push(d.alarms.test_period_min & 0xFF, (d.alarms.test_period_min >> 8) & 0xFF);
            out.push(d.device_settings.machine_off_threshold_mg & 0xFF, (d.device_settings.machine_off_threshold_mg >> 8) & 0xFF);
        }
        else if (port === 31) {
            var al = d.alarms;
            var mask = (al.temperature.enabled ? 1 : 0) | (al.acceleration_mg.axis_1.enabled ? 2 : 0) | (al.acceleration_mg.axis_2.enabled ? 4 : 0) | (al.acceleration_mg.axis_3.enabled ? 8 : 0) | (al.velocity_mips.axis_1.enabled ? 16 : 0) | (al.velocity_mips.axis_2.enabled ? 32 : 0) | (al.velocity_mips.axis_3.enabled ? 64 : 0);
            out.push(mask & 0xFF, (mask >> 8) & 0xFF);
            
            var t = Math.round(al.temperature.threshold_c * 100);
            out.push(t & 0xFF, (t >> 8) & 0xFF);
            
            [al.acceleration_mg.axis_1.threshold, al.acceleration_mg.axis_2.threshold, al.acceleration_mg.axis_3.threshold, al.velocity_mips.axis_1.threshold, al.velocity_mips.axis_2.threshold, al.velocity_mips.axis_3.threshold].forEach(function(v){ out.push(v & 0xFF, (v >> 8) & 0xFF); });
        }
        else if (port === 20) {
            // Encode opcode from slug OR raw
            var op = (typeof d.opcode === 'string') ? getOpId(d.opcode) : d.opcode;
            if (op == null) throw new Error("Invalid/Unknown Opcode");
            out.push(op);
            out.push(d.transaction_id || d.TransactionID);
        }
        else if (port === 21) {
            var mode = (d.value_size_mode !== undefined) ? d.value_size_mode : (d.ValueSizeMode || 0);
            var segs = d.segments || d.Segments || [];
            out.push(mode);
            out.push(segs.length);
            segs.forEach(function(s) { 
                if(mode===0) out.push(s & 0xFF); 
                else { out.push(s & 0xFF, (s >> 8) & 0xFF); }
            });
        }
        else if (port === 22) {
            // Encode command from slug OR raw
            var cmdRaw = (d.command_id !== undefined) ? d.command_id : d.CommandID;
            if (typeof cmdRaw === 'string') cmdRaw = getCmdId(cmdRaw);
            
            if (cmdRaw == null) throw new Error("Invalid/Unknown Command ID");
            
            var params = d.parameters || d.Parameters || [];
            out.push(cmdRaw & 0xFF, (cmdRaw >> 8) & 0xFF);
            if (Array.isArray(params)) {
                 params.forEach(function(p) { out.push(p); });
            }
        }
        else {
             res.errors.push("Unsupported Port: " + port);
        }

        res.fPort = port;
        res.bytes = out;
    } catch (e) { res.errors.push(e.message); }
    return res;
}

if (typeof module !== "undefined") {
    module.exports = { 
        decodeUplink: decodeUplink, 
        encodeDownlink: encodeDownlink, 
        decodeDownlink: decodeDownlink, 
        getCodecMetadata: function() { return { codecVersion: CODEC_VERSION }; } 
    };
}