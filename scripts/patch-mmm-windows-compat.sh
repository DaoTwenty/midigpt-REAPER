#!/usr/bin/env bash

set -euo pipefail

MMM_SRC_ROOT="${1:-}"

info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[ -n "$MMM_SRC_ROOT" ] || fail "Usage: $0 /path/to/mmm_refactored"
[ -d "$MMM_SRC_ROOT" ] || fail "mmm_refactored source directory not found: $MMM_SRC_ROOT"

replace_line_in_file() {
    local file_path="$1"
    local old_line="$2"
    local new_line="$3"
    local tmp_file=""

    [ -f "$file_path" ] || fail "Patch target not found: $file_path"

    if awk -v needle="$new_line" '
        {
            line = $0
            sub(/\r$/, "", line)
            if (line == needle) {
                found = 1
            }
        }
        END { exit found ? 0 : 1 }
    ' "$file_path"; then
        return 0
    fi

    tmp_file="$(mktemp "${TMPDIR:-/tmp}/mmm-win-compat.XXXXXX")"
    if awk -v old="$old_line" -v new="$new_line" '
        BEGIN { changed = 0 }
        {
            line = $0
            sub(/\r$/, "", line)
            if (line == old) {
                print new
                changed = 1
            } else {
                print line
            }
        }
        END { exit changed ? 0 : 1 }
    ' "$file_path" > "$tmp_file"; then
        mv "$tmp_file" "$file_path"
    else
        rm -f "$tmp_file"
        fail "Expected source line was not found in $file_path"
    fi
}

info "Applying Windows protobuf compatibility patch to $MMM_SRC_ROOT"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/inference/enum/gm.h" \
    "			result.push_back( descriptor->FindValueByNumber(kv.first)->name() );" \
    "			result.push_back(std::string(descriptor->FindValueByNumber(kv.first)->name()));"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/common/encoder/attribute_control.h" \
    "                output[field_name].push_back(enum_descriptor->value(i)->name());" \
    "                output[field_name].push_back(std::string(enum_descriptor->value(i)->name()));"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/common/encoder/attribute_control.h" \
    "                output[field_name][enum_descriptor->value(i)->name()] = i;" \
    "                output[field_name][std::string(enum_descriptor->value(i)->name())] = i;"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/common/encoder/attribute_control.h" \
    "            std::string name = descriptor->FindValueByNumber(static_cast<midi::GenreMusicmap>(i+1))->name();" \
    "            std::string name(descriptor->FindValueByNumber(static_cast<midi::GenreMusicmap>(i+1))->name());"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/common/encoder/encoder_base.h" \
    "      types.push_back(enum_descriptor->FindValueByNumber(c)->name());" \
    "      types.push_back(std::string(enum_descriptor->FindValueByNumber(c)->name()));"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/common/midi_parsing/util_protobuf.h" \
    "		return descriptor->FindValueByNumber(value)->name();" \
    "		return std::string(descriptor->FindValueByNumber(value)->name());"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/common/midi_parsing/util_protobuf.h" \
    "			values.push_back(descriptor->value(i)->name());" \
    "			values.push_back(std::string(descriptor->value(i)->name()));"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/inference/protobuf/validate.h" \
    "		if ((is_repeated) && (reflection->FieldSize(x, fd) != (int)raw_json[key_map[fd->name()]].as_array().size())) {" \
    "		if ((is_repeated) && (reflection->FieldSize(x, fd) != (int)raw_json[key_map[std::string(fd->name())]].as_array().size())) {"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/inference/protobuf/validate.h" \
    "            buffer << \"PROTOBUF ERROR : \" << \"invalid repeated field value :: \" << fd->name() << \" = \" << raw_json[key_map[fd->name()]].as<std::string>() << std::endl;" \
    "            buffer << \"PROTOBUF ERROR : \" << \"invalid repeated field value :: \" << fd->name() << \" = \" << raw_json[key_map[std::string(fd->name())]].as<std::string>() << std::endl;"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/inference/protobuf/validate.h" \
    "			if ((!is_repeated) && (!reflection->HasField(x, fd)) && (raw_json[key_map[fd->name()]].exists())) {" \
    "			if ((!is_repeated) && (!reflection->HasField(x, fd)) && (raw_json[key_map[std::string(fd->name())]].exists())) {"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/inference/protobuf/validate.h" \
    "				buffer << \"PROTOBUF ERROR : \" << \"invalid field value :: \" << fd->name() << \" = \" << raw_json[key_map[fd->name()]].as<std::string>() << std::endl;" \
    "				buffer << \"PROTOBUF ERROR : \" << \"invalid field value :: \" << fd->name() << \" = \" << raw_json[key_map[std::string(fd->name())]].as<std::string>() << std::endl;"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/inference/protobuf/validate.h" \
    "					validate_protobuf_fields_inner(reflection->GetRepeatedMessage(x,fd,index), raw_json[key_map[fd->name()]][index]);" \
    "					validate_protobuf_fields_inner(reflection->GetRepeatedMessage(x,fd,index), raw_json[key_map[std::string(fd->name())]][index]);"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/inference/protobuf/validate.h" \
    "					validate_protobuf_fields_inner(reflection->GetMessage(x,fd), raw_json[key_map[fd->name()]]);" \
    "					validate_protobuf_fields_inner(reflection->GetMessage(x,fd), raw_json[key_map[std::string(fd->name())]]);"

replace_line_in_file \
    "$MMM_SRC_ROOT/src/test/unit.cpp" \
    "        if (ignores.find(fd->name()) != ignores.end()) {" \
    "        if (ignores.find(std::string(fd->name())) != ignores.end()) {"

info "Windows protobuf compatibility patch applied"
