# Инструменты и каталоги сборки LumenLite (Iris + Vulkan-ready core)
PYTHON = python3
GLSLANG = glslangValidator
GLSLC := $(shell command -v glslc 2>/dev/null)

SRC_DIR = shaders/src
OUT_DIR = shaders/compiled
DIST_DIR = dist
PACK_ZIP = $(DIST_DIR)/LumenLite-Iris.zip

# Поиск опциональных Vulkan/Aperture .vert, .frag, .comp исходников в shaders/src
VERT_SOURCES = $(wildcard $(SRC_DIR)/*.vert)
FRAG_SOURCES = $(wildcard $(SRC_DIR)/*.frag)
COMP_SOURCES = $(wildcard $(SRC_DIR)/*.comp)
OBJECTS = $(patsubst $(SRC_DIR)/%, $(OUT_DIR)/%.spv, $(VERT_SOURCES) $(FRAG_SOURCES) $(COMP_SOURCES))

all: validate spirv

# Проверка всех Iris GLSL-шейдеров и компиляция ядра /lib/*.glsl в Vulkan SPIR-V
validate:
	$(PYTHON) scripts/validate_shaders.py

# Опциональная компиляция будущих Vulkan/Aperture шейдеров из shaders/src -> .spv
spirv: $(OUT_DIR) $(OBJECTS)

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

$(OUT_DIR)/%.spv: $(SRC_DIR)/%
ifdef GLSLC
	$(GLSLC) $< -o $@
else
	$(GLSLANG) -V $< -o $@
endif

# Упаковка готового шейдерпака для Minecraft (Iris)
pack: validate
	mkdir -p $(DIST_DIR)
	rm -f $(PACK_ZIP)
	zip -r $(PACK_ZIP) shaders -x "shaders/src/*" "shaders/compiled/*"

clean:
	rm -rf $(OUT_DIR) $(DIST_DIR)

.PHONY: all validate spirv pack clean
