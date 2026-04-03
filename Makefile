obj-m += hp_wmi_fan_test.o hp_wmi_fan_ctrl.o

KDIR := /lib/modules/$(shell uname -r)/build

all:
	make -C $(KDIR) M=$(PWD) modules

clean:
	make -C $(KDIR) M=$(PWD) clean

test: all
	@echo ""
	@echo "=== Build successful ==="
	@echo ""
	@echo "Fan test (read-only probing):"
	@echo "  sudo insmod hp_wmi_fan_test.ko"
	@echo "  sudo dmesg | grep hp_wmi_fan_test"
	@echo "  sudo rmmod hp_wmi_fan_test"
	@echo ""
	@echo "Fan control module:"
	@echo "  sudo insmod hp_wmi_fan_ctrl.ko"
	@echo "  cat /sys/module/hp_wmi_fan_ctrl/fans"
	@echo "  echo '30 30' | sudo tee /sys/module/hp_wmi_fan_ctrl/fans"
	@echo "  echo 'auto' | sudo tee /sys/module/hp_wmi_fan_ctrl/fans"
	@echo "  sudo rmmod hp_wmi_fan_ctrl"
	@echo ""
