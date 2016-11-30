#shared_global_scope

#import "os.odin"
#import "fmt.odin"
#import "mem.odin"

/*
Optimization_Level :: enum {
	DEBUG,
	RELEASE,
}

Bounds_Check_Mode :: enum {
	ON,
	OFF,
}

Build_Options :: struct {
	optimization_level: Optimization_Level

	bounds_check: Bounds_Check_Mode

	output_name: string
	output_path: string
}

build_options: Build_Options
*/

// IMPORTANT NOTE(bill): Do not change the order of any of this data
// The compiler relies upon this _exact_ order
Type_Info :: union {
	Member :: struct #ordered {
		name:      string     // can be empty if tuple
		type_info: ^Type_Info
		offset:    int        // offsets are not used in tuples
	}
	Record :: struct #ordered {
		fields:  []Member
		size:    int // in bytes
		align:   int // in bytes
		packed:  bool
		ordered: bool
	}

	Named: struct #ordered {
		name: string
		base: ^Type_Info // This will _not_ be a Type_Info.Named
	}
	Integer: struct #ordered {
		size:   int // in bytes
		signed: bool
	}
	Float: struct #ordered {
		size: int // in bytes
	}
	Any:     struct #ordered {}
	String:  struct #ordered {}
	Boolean: struct #ordered {}
	Pointer: struct #ordered {
		elem: ^Type_Info // nil -> rawptr
	}
	Maybe: struct #ordered {
		elem: ^Type_Info
	}
	Procedure: struct #ordered {
		params:   ^Type_Info // Type_Info.Tuple
		results:  ^Type_Info // Type_Info.Tuple
		variadic: bool
	}
	Array: struct #ordered {
		elem:      ^Type_Info
		elem_size: int
		count:     int
	}
	Slice: struct #ordered {
		elem:      ^Type_Info
		elem_size: int
	}
	Vector: struct #ordered {
		elem:      ^Type_Info
		elem_size: int
		count:     int
		align:     int
	}
	Tuple:     Record
	Struct:    Record
	Union:     Record
	Raw_Union: Record
	Enum: struct #ordered {
		base:   ^Type_Info
		values: []i64
		names:  []string
	}
}

type_info_base :: proc(info: ^Type_Info) -> ^Type_Info {
	if info == nil {
		return nil
	}
	base := info
	match type i : base {
	case Type_Info.Named:
		base = i.base
	}
	return base
}



assume :: proc(cond: bool) #foreign "llvm.assume"

__debug_trap       :: proc()        #foreign "llvm.debugtrap"
__trap             :: proc()        #foreign "llvm.trap"
read_cycle_counter :: proc() -> u64 #foreign "llvm.readcyclecounter"

bit_reverse16 :: proc(b: u16) -> u16 #foreign "llvm.bitreverse.i16"
bit_reverse32 :: proc(b: u32) -> u32 #foreign "llvm.bitreverse.i32"
bit_reverse64 :: proc(b: u64) -> u64 #foreign "llvm.bitreverse.i64"

byte_swap16 :: proc(b: u16) -> u16 #foreign "llvm.bswap.i16"
byte_swap32 :: proc(b: u32) -> u32 #foreign "llvm.bswap.i32"
byte_swap64 :: proc(b: u64) -> u64 #foreign "llvm.bswap.i64"

fmuladd32 :: proc(a, b, c: f32) -> f32 #foreign "llvm.fmuladd.f32"
fmuladd64 :: proc(a, b, c: f64) -> f64 #foreign "llvm.fmuladd.f64"







Allocator :: struct #ordered {
	Mode :: enum {
		ALLOC,
		FREE,
		FREE_ALL,
		RESIZE,
	}
	Proc :: type proc(allocator_data: rawptr, mode: Mode,
	                  size, alignment: int,
	                  old_memory: rawptr, old_size: int, flags: u64) -> rawptr


	procedure: Proc;
	data:      rawptr
}


Context :: struct #ordered {
	thread_id: int

	allocator: Allocator

	user_data:  rawptr
	user_index: int
}

#thread_local __context: Context


DEFAULT_ALIGNMENT :: align_of([vector 4]f32)


__check_context :: proc() {
	c := ^__context

	if c.allocator.procedure == nil {
		c.allocator = default_allocator()
	}
	if c.thread_id == 0 {
		c.thread_id = os.current_thread_id()
	}
}

alloc :: proc(size: int) -> rawptr #inline { return alloc_align(size, DEFAULT_ALIGNMENT) }

alloc_align :: proc(size, alignment: int) -> rawptr #inline {
	__check_context()
	a := context.allocator
	return a.procedure(a.data, Allocator.Mode.ALLOC, size, alignment, nil, 0, 0)
}

free :: proc(ptr: rawptr) #inline {
	__check_context()
	a := context.allocator
	if ptr != nil {
		a.procedure(a.data, Allocator.Mode.FREE, 0, 0, ptr, 0, 0)
	}
}
free_all :: proc() #inline {
	__check_context()
	a := context.allocator
	a.procedure(a.data, Allocator.Mode.FREE_ALL, 0, 0, nil, 0, 0)
}


resize       :: proc(ptr: rawptr, old_size, new_size: int) -> rawptr #inline { return resize_align(ptr, old_size, new_size, DEFAULT_ALIGNMENT) }
resize_align :: proc(ptr: rawptr, old_size, new_size, alignment: int) -> rawptr #inline {
	__check_context()
	a := context.allocator
	return a.procedure(a.data, Allocator.Mode.RESIZE, new_size, alignment, ptr, old_size, 0)
}



default_resize_align :: proc(old_memory: rawptr, old_size, new_size, alignment: int) -> rawptr {
	if old_memory == nil {
		return alloc_align(new_size, alignment)
	}

	if new_size == 0 {
		free(old_memory)
		return nil
	}

	if new_size == old_size {
		return old_memory
	}

	new_memory := alloc_align(new_size, alignment)
	if new_memory == nil {
		return nil
	}

	mem.copy(new_memory, old_memory, min(old_size, new_size));
	free(old_memory)
	return new_memory
}


default_allocator_proc :: proc(allocator_data: rawptr, mode: Allocator.Mode,
                               size, alignment: int,
                               old_memory: rawptr, old_size: int, flags: u64) -> rawptr {
	using Allocator.Mode
/*
	match mode {
	case ALLOC:
		total_size := size + alignment + size_of(mem.AllocationHeader)
		ptr := os.heap_alloc(total_size)
		header := ptr as ^mem.AllocationHeader
		ptr = mem.align_forward(header+1, alignment)
		mem.allocation_header_fill(header, ptr, size)
		return mem.zero(ptr, size)

	case FREE:
		os.heap_free(mem.allocation_header(old_memory))
		return nil

	case FREE_ALL:
		// NOTE(bill): Does nothing

	case RESIZE:
		total_size := size + alignment + size_of(mem.AllocationHeader)
		ptr := os.heap_resize(mem.allocation_header(old_memory), total_size)
		header := ptr as ^mem.AllocationHeader
		ptr = mem.align_forward(header+1, alignment)
		mem.allocation_header_fill(header, ptr, size)
		return mem.zero(ptr, size)
	}
*/
	match mode {
	case ALLOC:
		return os.heap_alloc(size)

	case FREE:
		os.heap_free(old_memory)
		return nil

	case FREE_ALL:
		// NOTE(bill): Does nothing

	case RESIZE:
		return os.heap_resize(old_memory, size)
	}

	return nil
}

default_allocator :: proc() -> Allocator {
	return Allocator{
		procedure = default_allocator_proc,
		data = nil,
	}
}











__string_eq :: proc(a, b: string) -> bool {
	if a.count != b.count {
		return false
	}
	if a.data == b.data {
		return true
	}
	return mem.compare(a.data, b.data, a.count) == 0
}

__string_cmp :: proc(a, b : string) -> int {
	return mem.compare(a.data, b.data, min(a.count, b.count))
}

__string_ne :: proc(a, b: string) -> bool #inline { return !__string_eq(a, b) }
__string_lt :: proc(a, b: string) -> bool #inline { return __string_cmp(a, b) < 0 }
__string_gt :: proc(a, b: string) -> bool #inline { return __string_cmp(a, b) > 0 }
__string_le :: proc(a, b: string) -> bool #inline { return __string_cmp(a, b) <= 0 }
__string_ge :: proc(a, b: string) -> bool #inline { return __string_cmp(a, b) >= 0 }


__assert :: proc(file: string, line, column: int, msg: string) #inline {
	fmt.fprintf(os.stderr, "%(%:%) Runtime assertion: %\n",
	            file, line, column, msg)
	__debug_trap()
}

__bounds_check_error :: proc(file: string, line, column: int,
                             index, count: int) {
	if 0 <= index && index < count {
		return
	}
	fmt.fprintf(os.stderr, "%(%:%) Index % is out of bounds range [0, %)\n",
	            file, line, column, index, count)
	__debug_trap()
}

__slice_expr_error :: proc(file: string, line, column: int,
                           low, high, max: int) {
	if 0 <= low && low <= high && high <= max {
		return
	}
	fmt.fprintf(os.stderr, "%(%:%) Invalid slice indices: [%:%:%]\n",
	            file, line, column, low, high, max)
	__debug_trap()
}
__substring_expr_error :: proc(file: string, line, column: int,
                               low, high: int) {
	if 0 <= low && low <= high {
		return
	}
	fmt.fprintf(os.stderr, "%(%:%) Invalid substring indices: [%:%:%]\n",
	            file, line, column, low, high)
	__debug_trap()
}

__enum_to_string :: proc(info: ^Type_Info, value: i64) -> string {
	match type ti : type_info_base(info) {
	case Type_Info.Enum:
		// TODO(bill): Search faster than linearly
		for i := 0; i < ti.values.count; i++ {
			if ti.values[i] == value {
				return ti.names[i]
			}
		}
	}
	return ""
}

