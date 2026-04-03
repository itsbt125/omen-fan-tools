/*
 * hp_wmi_fan_test.c - Minimal kernel module to test WMI fan queries on HP Omen 8BCA
 *
 * Tests whether WMI queries 0x2E (FAN_SPEED_SET) and 0x2D (VICTUS_S_FAN_SPEED_GET)
 * work on this board, without modifying the main hp_wmi driver.
 *
 * Build: make
 * Load:  sudo insmod hp_wmi_fan_test.ko
 * Check: sudo dmesg | grep hp_wmi_fan_test
 * Unload: sudo rmmod hp_wmi_fan_test
 *
 * The module runs all tests on load and reports results via dmesg.
 * It does NOT persist or change any fan settings permanently.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/wmi.h>
#include <linux/acpi.h>

#define HPWMI_BIOS_GUID "5FB7F034-2C63-45E9-BE91-3D44E2C707E4"

#define HPWMI_GM 0x20008

/* WMI query IDs from hp_wmi.c */
#define HPWMI_FAN_COUNT_GET         0x10
#define HPWMI_FAN_SPEED_GET         0x11
#define HPWMI_FAN_SPEED_MAX_GET     0x26
#define HPWMI_FAN_SPEED_MAX_SET     0x27
#define HPWMI_GET_SYSTEM_DESIGN     0x28
#define HPWMI_VICTUS_S_FAN_GET      0x2D
#define HPWMI_FAN_SPEED_SET         0x2E

struct bios_args {
	u32 signature;
	u32 command;
	u32 commandtype;
	u32 datasize;
	u8 data[128];
} __packed;

struct bios_return {
	u32 sigpass;
	u32 return_code;
} __packed;

static int encode_outsize(int outsize)
{
	if (outsize > 4096) return -EINVAL;
	if (outsize > 1024) return 5;
	if (outsize > 128)  return 4;
	if (outsize > 4)    return 3;
	if (outsize > 0)    return 2;
	return 1;
}

static int wmi_query(int query_id, void *indata, int insize, void *outdata, int outsize)
{
	struct acpi_buffer input, output = { ACPI_ALLOCATE_BUFFER, NULL };
	struct bios_return *bret;
	union acpi_object *obj;
	struct bios_args args;
	int mid, ret;

	mid = encode_outsize(outsize);
	if (mid < 0)
		return mid;

	memset(&args, 0, sizeof(args));
	args.signature = 0x55434553; /* "SECU" */
	args.command = HPWMI_GM;
	args.commandtype = query_id;
	args.datasize = insize;
	if (indata && insize > 0 && insize <= sizeof(args.data))
		memcpy(args.data, indata, insize);

	input.length = sizeof(args);
	input.pointer = &args;

	ret = wmi_evaluate_method(HPWMI_BIOS_GUID, 0, mid, &input, &output);
	if (ret) {
		pr_info("hp_wmi_fan_test: query 0x%02X WMI call failed: %d\n", query_id, ret);
		return ret;
	}

	obj = output.pointer;
	if (!obj) {
		pr_info("hp_wmi_fan_test: query 0x%02X returned NULL\n", query_id);
		return -EINVAL;
	}

	if (obj->type != ACPI_TYPE_BUFFER) {
		pr_info("hp_wmi_fan_test: query 0x%02X returned type %d (expected buffer)\n",
			query_id, obj->type);
		kfree(obj);
		return -EINVAL;
	}

	bret = (struct bios_return *)obj->buffer.pointer;
	if (bret->return_code) {
		pr_info("hp_wmi_fan_test: query 0x%02X BIOS return code: 0x%08X\n",
			query_id, bret->return_code);
		kfree(obj);
		return bret->return_code;
	}

	/* Copy output data (skip the bios_return header) */
	if (outdata && outsize > 0) {
		int available = obj->buffer.length - sizeof(struct bios_return);
		int copy_size = min(outsize, available);
		if (copy_size > 0)
			memcpy(outdata, obj->buffer.pointer + sizeof(struct bios_return), copy_size);
	}

	kfree(obj);
	return 0;
}

static void test_fan_count(void)
{
	u8 data[4] = {};
	int ret;

	ret = wmi_query(HPWMI_FAN_COUNT_GET, data, 1, data, sizeof(data));
	pr_info("hp_wmi_fan_test: [0x10] FAN_COUNT_GET: ret=%d, count=%d (bytes: %02X %02X %02X %02X)\n",
		ret, data[0], data[0], data[1], data[2], data[3]);
}

static void test_fan_speed_get(void)
{
	int fan;
	for (fan = 0; fan < 2; fan++) {
		char data[4] = { fan, 0, 0, 0 };
		int ret = wmi_query(HPWMI_FAN_SPEED_GET, data, 1, data, sizeof(data));
		if (ret == 0) {
			int rpm = (data[2] << 8) | data[3];
			pr_info("hp_wmi_fan_test: [0x11] FAN_SPEED_GET fan%d: ret=%d, RPM=%d (bytes: %02X %02X %02X %02X)\n",
				fan, ret, rpm, data[0], data[1], data[2], data[3]);
		} else {
			pr_info("hp_wmi_fan_test: [0x11] FAN_SPEED_GET fan%d: ret=%d (FAILED)\n", fan, ret);
		}
	}
}

static void test_victus_s_fan_get(void)
{
	u8 data[128] = {};
	int ret;

	ret = wmi_query(HPWMI_VICTUS_S_FAN_GET, data, 1, data, sizeof(data));
	if (ret == 0) {
		pr_info("hp_wmi_fan_test: [0x2D] VICTUS_S_FAN_GET: ret=%d, fan0=%d*100=%dRPM, fan1=%d*100=%dRPM\n",
			ret, data[0], data[0]*100, data[1], data[1]*100);
		pr_info("hp_wmi_fan_test: [0x2D] first 16 bytes: %*ph\n", 16, data);
	} else {
		pr_info("hp_wmi_fan_test: [0x2D] VICTUS_S_FAN_GET: ret=%d (NOT SUPPORTED or failed)\n", ret);
	}
}

static void test_fan_speed_max_get(void)
{
	int val = 0;
	int ret = wmi_query(HPWMI_FAN_SPEED_MAX_GET, &val, 0, &val, sizeof(val));
	pr_info("hp_wmi_fan_test: [0x26] FAN_SPEED_MAX_GET: ret=%d, val=%d (0=auto, 1=max)\n", ret, val);
}

static void test_system_design_data(void)
{
	u8 data[128] = {};
	int ret = wmi_query(HPWMI_GET_SYSTEM_DESIGN, data, 0, data, sizeof(data));
	if (ret == 0) {
		pr_info("hp_wmi_fan_test: [0x28] SYSTEM_DESIGN_DATA: ret=%d\n", ret);
		pr_info("hp_wmi_fan_test: [0x28] first 32 bytes: %*ph\n", 32, data);
	} else {
		pr_info("hp_wmi_fan_test: [0x28] SYSTEM_DESIGN_DATA: ret=%d (FAILED)\n", ret);
	}
}

static void test_fan_speed_set_readback(void)
{
	/*
	 * SAFETY: We send {0x00, 0x00} which means "automatic" — this is the
	 * same thing hp_wmi_fan_speed_reset() does. It should be safe and
	 * just confirm auto mode. We do NOT send non-zero values yet.
	 */
	u8 fan_speed[2] = { 0x00, 0x00 };  /* HP_FAN_SPEED_AUTOMATIC for both fans */
	int ret;

	ret = wmi_query(HPWMI_FAN_SPEED_SET, fan_speed, sizeof(fan_speed), NULL, 0);
	pr_info("hp_wmi_fan_test: [0x2E] FAN_SPEED_SET {0x00,0x00} (auto): ret=%d %s\n",
		ret, ret == 0 ? "SUCCESS - query 0x2E is SUPPORTED!" : "FAILED - query not supported");
}

static int __init hp_wmi_fan_test_init(void)
{
	pr_info("hp_wmi_fan_test: === HP Omen 8BCA WMI Fan Query Test ===\n");
	pr_info("hp_wmi_fan_test: Testing WMI GUID: %s\n", HPWMI_BIOS_GUID);

	if (!wmi_has_guid(HPWMI_BIOS_GUID)) {
		pr_err("hp_wmi_fan_test: WMI GUID not found! HP WMI not available.\n");
		return -ENODEV;
	}

	pr_info("hp_wmi_fan_test: WMI GUID found. Running tests...\n\n");

	test_fan_count();
	test_fan_speed_get();
	test_victus_s_fan_get();
	test_fan_speed_max_get();
	test_system_design_data();
	test_fan_speed_set_readback();

	pr_info("hp_wmi_fan_test: === Tests complete. Check results above. ===\n");
	pr_info("hp_wmi_fan_test: If 0x2E returned SUCCESS, manual fan control via WMI is viable.\n");
	pr_info("hp_wmi_fan_test: If 0x2D returned SUCCESS, this board uses Victus-S style queries.\n");
	pr_info("hp_wmi_fan_test: Unload with: sudo rmmod hp_wmi_fan_test\n");

	return 0;
}

static void __exit hp_wmi_fan_test_exit(void)
{
	pr_info("hp_wmi_fan_test: module unloaded\n");
}

module_init(hp_wmi_fan_test_init);
module_exit(hp_wmi_fan_test_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("omen-fan-tools");
MODULE_DESCRIPTION("HP Omen 8BCA WMI fan query test module");
