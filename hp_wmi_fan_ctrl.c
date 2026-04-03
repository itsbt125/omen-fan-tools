/*
 * hp_wmi_fan_ctrl.c - WMI fan control module for HP Omen 16-xf0xxx (Board 8BCA)
 *
 * Provides direct fan speed control via WMI query 0x2E and reading via 0x2D.
 * Exposes sysfs interface at /sys/module/hp_wmi_fan_ctrl/parameters/
 *
 * Build: make
 * Load:  sudo insmod hp_wmi_fan_ctrl.ko
 * Usage:
 *   # Read current fan speeds (RPM)
 *   cat /sys/module/hp_wmi_fan_ctrl/fans
 *
 *   # Set fan speeds (0 = auto, 1-255 = manual speed)
 *   # Values are in firmware units: RPM = value * 100
 *   echo "30 30" > /sys/module/hp_wmi_fan_ctrl/fans       # both fans ~3000 RPM
 *   echo "0 0"   > /sys/module/hp_wmi_fan_ctrl/fans        # return to auto
 *   echo "auto"  > /sys/module/hp_wmi_fan_ctrl/fans         # return to auto
 *   echo "max"   > /sys/module/hp_wmi_fan_ctrl/fans          # maximum speed
 *
 * The module maintains a heartbeat every 90 seconds to prevent the firmware's
 * 120-second timeout from reverting to auto mode.
 *
 * Unload: sudo rmmod hp_wmi_fan_ctrl (fans return to auto)
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/wmi.h>
#include <linux/acpi.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>
#include <linux/mutex.h>

#define HPWMI_BIOS_GUID "5FB7F034-2C63-45E9-BE91-3D44E2C707E4"
#define HPWMI_GM 0x20008

#define HPWMI_FAN_COUNT_GET     0x10
#define HPWMI_VICTUS_S_FAN_GET  0x2D
#define HPWMI_FAN_SPEED_SET     0x2E

#define HEARTBEAT_INTERVAL_SEC  90
#define FAN_COUNT               2

static DEFINE_MUTEX(fan_lock);
static u8 current_fan_speed[FAN_COUNT];  /* 0 = auto, >0 = manual */
static bool manual_mode;
static struct delayed_work heartbeat_work;
static struct kobject *fan_kobj;

static int encode_outsize(int outsize)
{
	if (outsize > 4096) return -EINVAL;
	if (outsize > 1024) return 5;
	if (outsize > 128)  return 4;
	if (outsize > 4)    return 3;
	if (outsize > 0)    return 2;
	return 1;
}

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
	args.signature = 0x55434553;
	args.command = HPWMI_GM;
	args.commandtype = query_id;
	args.datasize = insize;
	if (indata && insize > 0 && insize <= sizeof(args.data))
		memcpy(args.data, indata, insize);

	input.length = sizeof(args);
	input.pointer = &args;

	ret = wmi_evaluate_method(HPWMI_BIOS_GUID, 0, mid, &input, &output);
	if (ret)
		return ret;

	obj = output.pointer;
	if (!obj)
		return -EINVAL;

	if (obj->type != ACPI_TYPE_BUFFER) {
		kfree(obj);
		return -EINVAL;
	}

	bret = (struct bios_return *)obj->buffer.pointer;
	if (bret->return_code) {
		int rc = bret->return_code;
		kfree(obj);
		return rc;
	}

	if (outdata && outsize > 0) {
		int available = obj->buffer.length - sizeof(struct bios_return);
		int copy_size = min(outsize, available);
		if (copy_size > 0)
			memcpy(outdata, obj->buffer.pointer + sizeof(struct bios_return), copy_size);
	}

	kfree(obj);
	return 0;
}

static int fan_get_speeds(int *rpm0, int *rpm1)
{
	u8 data[128] = {};
	int ret;

	ret = wmi_query(HPWMI_VICTUS_S_FAN_GET, data, 1, data, sizeof(data));
	if (ret)
		return ret;

	*rpm0 = data[0] * 100;
	*rpm1 = data[1] * 100;
	return 0;
}

static int fan_trigger_userdefine(void)
{
	u8 data[4] = {};
	return wmi_query(HPWMI_FAN_COUNT_GET, data, 1, data, sizeof(data));
}

static int fan_set_speeds(u8 speed0, u8 speed1)
{
	u8 fan_speed[2] = { speed0, speed1 };
	int ret;

	/* Trigger user-defined mode first */
	ret = fan_trigger_userdefine();
	if (ret)
		pr_warn("hp_wmi_fan_ctrl: userdefine trigger failed: %d\n", ret);

	ret = wmi_query(HPWMI_FAN_SPEED_SET, fan_speed, sizeof(fan_speed), NULL, 0);
	if (ret)
		return ret;

	return 0;
}

static void heartbeat_fn(struct work_struct *work)
{
	mutex_lock(&fan_lock);
	if (manual_mode) {
		int ret = fan_set_speeds(current_fan_speed[0], current_fan_speed[1]);
		if (ret)
			pr_warn("hp_wmi_fan_ctrl: heartbeat reapply failed: %d\n", ret);
		else
			pr_debug("hp_wmi_fan_ctrl: heartbeat reapplied fan speeds %d/%d\n",
				 current_fan_speed[0], current_fan_speed[1]);
		schedule_delayed_work(&heartbeat_work,
				      msecs_to_jiffies(HEARTBEAT_INTERVAL_SEC * 1000));
	}
	mutex_unlock(&fan_lock);
}

/* sysfs: /sys/module/hp_wmi_fan_ctrl/fans */

static ssize_t fans_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	int rpm0, rpm1, ret;

	ret = fan_get_speeds(&rpm0, &rpm1);
	if (ret)
		return sysfs_emit(buf, "error: %d\n", ret);

	mutex_lock(&fan_lock);
	ret = sysfs_emit(buf, "fan0_rpm=%d fan1_rpm=%d mode=%s",
			 rpm0, rpm1, manual_mode ? "manual" : "auto");
	if (manual_mode)
		ret += sysfs_emit_at(buf, ret, " set0=%d set1=%d",
				     current_fan_speed[0], current_fan_speed[1]);
	ret += sysfs_emit_at(buf, ret, "\n");
	mutex_unlock(&fan_lock);

	return ret;
}

static ssize_t fans_store(struct kobject *kobj, struct kobj_attribute *attr,
			   const char *buf, size_t count)
{
	unsigned int speed0, speed1;
	int ret;

	mutex_lock(&fan_lock);

	if (sysfs_streq(buf, "auto")) {
		/* Return to automatic */
		ret = fan_set_speeds(0, 0);
		if (ret) {
			mutex_unlock(&fan_lock);
			return ret;
		}
		manual_mode = false;
		current_fan_speed[0] = 0;
		current_fan_speed[1] = 0;
		cancel_delayed_work(&heartbeat_work);
		pr_info("hp_wmi_fan_ctrl: set to auto mode\n");
	} else if (sysfs_streq(buf, "max")) {
		/* Maximum speed — use 0xFF for both */
		ret = fan_set_speeds(0xFF, 0xFF);
		if (ret) {
			mutex_unlock(&fan_lock);
			return ret;
		}
		manual_mode = true;
		current_fan_speed[0] = 0xFF;
		current_fan_speed[1] = 0xFF;
		schedule_delayed_work(&heartbeat_work,
				      msecs_to_jiffies(HEARTBEAT_INTERVAL_SEC * 1000));
		pr_info("hp_wmi_fan_ctrl: set to max mode\n");
	} else if (sscanf(buf, "%u %u", &speed0, &speed1) == 2) {
		if (speed0 > 255 || speed1 > 255) {
			mutex_unlock(&fan_lock);
			return -EINVAL;
		}
		ret = fan_set_speeds(speed0, speed1);
		if (ret) {
			mutex_unlock(&fan_lock);
			return ret;
		}
		if (speed0 == 0 && speed1 == 0) {
			manual_mode = false;
			cancel_delayed_work(&heartbeat_work);
			pr_info("hp_wmi_fan_ctrl: set to auto mode (0 0)\n");
		} else {
			manual_mode = true;
			current_fan_speed[0] = speed0;
			current_fan_speed[1] = speed1;
			schedule_delayed_work(&heartbeat_work,
					      msecs_to_jiffies(HEARTBEAT_INTERVAL_SEC * 1000));
			pr_info("hp_wmi_fan_ctrl: set fan speeds %u/%u\n", speed0, speed1);
		}
	} else {
		mutex_unlock(&fan_lock);
		return -EINVAL;
	}

	mutex_unlock(&fan_lock);
	return count;
}

static struct kobj_attribute fans_attr = __ATTR_RW(fans);

static int __init hp_wmi_fan_ctrl_init(void)
{
	int ret, rpm0, rpm1;

	if (!wmi_has_guid(HPWMI_BIOS_GUID)) {
		pr_err("hp_wmi_fan_ctrl: HP WMI GUID not found\n");
		return -ENODEV;
	}

	/* Verify fan read works */
	ret = fan_get_speeds(&rpm0, &rpm1);
	if (ret) {
		pr_err("hp_wmi_fan_ctrl: cannot read fan speeds (ret=%d)\n", ret);
		return -ENODEV;
	}

	/* Create sysfs entry under /sys/module/hp_wmi_fan_ctrl/ */
	fan_kobj = &THIS_MODULE->mkobj.kobj;
	ret = sysfs_create_file(fan_kobj, &fans_attr.attr);
	if (ret) {
		pr_err("hp_wmi_fan_ctrl: sysfs_create_file failed: %d\n", ret);
		return ret;
	}

	INIT_DELAYED_WORK(&heartbeat_work, heartbeat_fn);

	pr_info("hp_wmi_fan_ctrl: loaded. fan0=%dRPM fan1=%dRPM\n", rpm0, rpm1);
	pr_info("hp_wmi_fan_ctrl: control via /sys/module/hp_wmi_fan_ctrl/fans\n");
	return 0;
}

static void __exit hp_wmi_fan_ctrl_exit(void)
{
	/* Cancel heartbeat and return fans to auto */
	cancel_delayed_work_sync(&heartbeat_work);

	mutex_lock(&fan_lock);
	if (manual_mode) {
		fan_set_speeds(0, 0);
		pr_info("hp_wmi_fan_ctrl: restored auto fan mode\n");
	}
	manual_mode = false;
	mutex_unlock(&fan_lock);

	sysfs_remove_file(fan_kobj, &fans_attr.attr);
	pr_info("hp_wmi_fan_ctrl: unloaded\n");
}

module_init(hp_wmi_fan_ctrl_init);
module_exit(hp_wmi_fan_ctrl_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("omen-fan-tools");
MODULE_DESCRIPTION("HP Omen 8BCA WMI fan speed control");
