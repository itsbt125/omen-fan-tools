obj-m += hp_wmi_fan_ctrl.o

KDIR := /lib/modules/$(shell uname -r)/build
MDIR := $(CURDIR)

all:
	$(MAKE) -C $(KDIR) M=$(MDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(MDIR) clean

test: all
	@echo ""
	@echo "=== Build successful ==="
	@echo ""
	@echo "Fan control module:"
	@echo "  sudo insmod hp_wmi_fan_ctrl.ko"
	@echo "  cat /sys/module/hp_wmi_fan_ctrl/fans"
	@echo "  echo '30 30' | sudo tee /sys/module/hp_wmi_fan_ctrl/fans"
	@echo "  echo 'auto' | sudo tee /sys/module/hp_wmi_fan_ctrl/fans"
	@echo "  sudo rmmod hp_wmi_fan_ctrl"
	@echo ""
