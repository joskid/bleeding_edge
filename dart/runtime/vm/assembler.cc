// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/assembler.h"

#include "platform/utils.h"
#include "vm/cpu.h"
#include "vm/heap.h"
#include "vm/memory_region.h"
#include "vm/os.h"
#include "vm/zone.h"

namespace dart {

static uword NewContents(intptr_t capacity) {
  StackZone* zone = Isolate::Current()->current_zone();
  uword result = zone->AllocUnsafe(capacity);
#if defined(DEBUG)
  // Initialize the buffer with kBreakPointInstruction to force a break
  // point if we ever execute an uninitialized part of the code buffer.
  Assembler::InitializeMemoryWithBreakpoints(result, capacity);
#endif
  return result;
}


#if defined(DEBUG)
AssemblerBuffer::EnsureCapacity::EnsureCapacity(AssemblerBuffer* buffer) {
  if (buffer->cursor() >= buffer->limit()) buffer->ExtendCapacity();
  // In debug mode, we save the assembler buffer along with the gap
  // size before we start emitting to the buffer. This allows us to
  // check that any single generated instruction doesn't overflow the
  // limit implied by the minimum gap size.
  buffer_ = buffer;
  gap_ = ComputeGap();
  // Make sure that extending the capacity leaves a big enough gap
  // for any kind of instruction.
  ASSERT(gap_ >= kMinimumGap);
  // Mark the buffer as having ensured the capacity.
  ASSERT(!buffer->HasEnsuredCapacity());  // Cannot nest.
  buffer->has_ensured_capacity_ = true;
}


AssemblerBuffer::EnsureCapacity::~EnsureCapacity() {
  // Unmark the buffer, so we cannot emit after this.
  buffer_->has_ensured_capacity_ = false;
  // Make sure the generated instruction doesn't take up more
  // space than the minimum gap.
  intptr_t delta = gap_ - ComputeGap();
  ASSERT(delta <= kMinimumGap);
}
#endif


AssemblerBuffer::AssemblerBuffer()
    : pointer_offsets_(new ZoneGrowableArray<int>(16)) {
  static const intptr_t kInitialBufferCapacity = 4 * KB;
  contents_ = NewContents(kInitialBufferCapacity);
  cursor_ = contents_;
  limit_ = ComputeLimit(contents_, kInitialBufferCapacity);
  fixup_ = NULL;
#if defined(DEBUG)
  has_ensured_capacity_ = false;
  fixups_processed_ = false;
#endif

  // Verify internal state.
  ASSERT(Capacity() == kInitialBufferCapacity);
  ASSERT(Size() == 0);
}


AssemblerBuffer::~AssemblerBuffer() {
}


void AssemblerBuffer::ProcessFixups(const MemoryRegion& region) {
  AssemblerFixup* fixup = fixup_;
  while (fixup != NULL) {
    fixup->Process(region, fixup->position());
    fixup = fixup->previous();
  }
}


void AssemblerBuffer::FinalizeInstructions(const MemoryRegion& instructions) {
  // Copy the instructions from the buffer.
  MemoryRegion from(reinterpret_cast<void*>(contents()), Size());
  instructions.CopyFrom(0, from);

  // Process fixups in the instructions.
  ProcessFixups(instructions);
#if defined(DEBUG)
  fixups_processed_ = true;
#endif
}


void AssemblerBuffer::ExtendCapacity() {
  intptr_t old_size = Size();
  intptr_t old_capacity = Capacity();
  intptr_t new_capacity =
      Utils::Minimum(old_capacity * 2, old_capacity + 1 * MB);
  if (new_capacity < old_capacity) {
    FATAL("Unexpected overflow in AssemblerBuffer::ExtendCapacity");
  }

  // Allocate the new data area and copy contents of the old one to it.
  uword new_contents = NewContents(new_capacity);
  memmove(reinterpret_cast<void*>(new_contents),
          reinterpret_cast<void*>(contents_),
          old_size);

  // Compute the relocation delta and switch to the new contents area.
  intptr_t delta = new_contents - contents_;
  contents_ = new_contents;

  // Update the cursor and recompute the limit.
  cursor_ += delta;
  limit_ = ComputeLimit(new_contents, new_capacity);

  // Verify internal state.
  ASSERT(Capacity() == new_capacity);
  ASSERT(Size() == old_size);
}


class PatchCodeWithHandle : public AssemblerFixup {
 public:
  PatchCodeWithHandle(ZoneGrowableArray<int>* pointer_offsets,
                      const Object& object)
      : pointer_offsets_(pointer_offsets), object_(object) {
  }

  void Process(const MemoryRegion& region, int position) {
    // Patch the handle into the code. Once the instructions are installed into
    // a raw code object and the pointer offsets are setup, the handle is
    // resolved.
    region.Store<const Object*>(position, &object_);
    pointer_offsets_->Add(position);
  }

 private:
  ZoneGrowableArray<int>* pointer_offsets_;
  const Object& object_;
};


void AssemblerBuffer::EmitObject(const Object& object) {
  // Since we are going to store the handle as part of the fixup information
  // the handle needs to be a zone handle.
  ASSERT(object.IsZoneHandle());
  ASSERT(object.IsOld());
  EmitFixup(new PatchCodeWithHandle(pointer_offsets_, object));
  cursor_ += kWordSize;  // Reserve space for pointer.
}


// Shared macros are implemented here.
void Assembler::Unimplemented(const char* message) {
  const char* format = "Unimplemented: %s";
  const intptr_t len = OS::SNPrint(NULL, 0, format, message);
  char* buffer = reinterpret_cast<char*>(malloc(len + 1));
  OS::SNPrint(buffer, len + 1, format, message);
  Stop(buffer);
}


void Assembler::Untested(const char* message) {
  const char* format = "Untested: %s";
  const intptr_t len = OS::SNPrint(NULL, 0, format, message);
  char* buffer = reinterpret_cast<char*>(malloc(len + 1));
  OS::SNPrint(buffer, len + 1, format, message);
  Stop(buffer);
}


void Assembler::Unreachable(const char* message) {
  const char* format = "Unreachable: %s";
  const intptr_t len = OS::SNPrint(NULL, 0, format, message);
  char* buffer = reinterpret_cast<char*>(malloc(len + 1));
  OS::SNPrint(buffer, len + 1, format, message);
  Stop(buffer);
}

}  // namespace dart
