# host array

export MtlArray

mutable struct MtlArray{T,N} <: AbstractGPUArray{T,N}
  buffer::MtlBuffer{T}
  dims::Dims{N}

  dev::MtlDevice
end


## constructors

# type and dimensionality specified, accepting dims as tuples of Ints
function MtlArray{T,N}(::UndefInitializer, dims::Dims{N}; storage=Shared) where {T,N}
    dev = device()
    # Check that requested size is not larger than maximum buffer size allowed
    sizeof(T) * prod(dims) > dev.maxBufferLength && error("Too large of Metal buffer requested of size $(Base.format_bytes(sizeof(T) * prod(dims))) (Max: $(Base.format_bytes(dev.maxBufferLength)))")
    buf = alloc(T, dev, prod(dims); storage=storage)

    obj = MtlArray{T,N}(buf, dims, dev)
    finalizer(obj) do arr
        free(arr.buffer)
    end
    return obj
end

# type and dimensionality specified, accepting dims as series of Ints
MtlArray{T,N}(::UndefInitializer, dims::Integer...) where {T,N} = MtlArray{T,N}(undef, Dims(dims))

# type but not dimensionality specified
MtlArray{T}(::UndefInitializer, dims::Dims{N}) where {T,N} = MtlArray{T,N}(undef, dims)
MtlArray{T}(::UndefInitializer, dims::Integer...) where {T} =
    MtlArray{T}(undef, convert(Tuple{Vararg{Int}}, dims))

# empty vector constructor
MtlArray{T,1}() where {T} = MtlArray{T,1}(undef, 0)

Base.similar(a::MtlArray{T,N}) where {T,N} = MtlArray{T,N}(undef, size(a))
Base.similar(a::MtlArray{T}, dims::Base.Dims{N}) where {T,N} = MtlArray{T,N}(undef, dims)
Base.similar(a::MtlArray, ::Type{T}, dims::Base.Dims{N}) where {T,N} = MtlArray{T,N}(undef, dims)

function Base.copy(a::MtlArray{T,N}) where {T,N}
  b = similar(a)
  @inbounds copyto!(b, a)
end

## array interface

Base.elsize(::Type{<:MtlArray{T}}) where {T} = sizeof(T)

Base.size(x::MtlArray) = x.dims
Base.sizeof(x::MtlArray) = Base.elsize(x) * length(x)

Base.pointer(x::MtlArray) = x.buffer
#Base.pointer(x::MtlArray, i::Integer) = x.ptr + (i-1) * Base.elsize(x)


## interop with other arrays

@inline function MtlArray{T,N}(xs::AbstractArray{T,N}) where {T,N}
  A = MtlArray{T,N}(undef, size(xs))
  copyto!(A, xs)
  return A
end

MtlArray{T,N}(xs::AbstractArray{S,N}) where {T,N,S} = MtlArray{T,N}(map(T, xs))

# underspecified constructors
MtlArray{T}(xs::AbstractArray{S,N}) where {T,N,S} = MtlArray{T,N}(xs)
(::Type{MtlArray{T,N} where T})(x::AbstractArray{S,N}) where {S,N} = MtlArray{S,N}(x)
MtlArray(A::AbstractArray{T,N}) where {T,N} = MtlArray{T,N}(A)

# idempotency
MtlArray{T,N}(xs::MtlArray{T,N}) where {T,N} = xs


## conversions

Base.convert(::Type{T}, x::T) where T <: MtlArray = x


## interop with C libraries

Base.unsafe_convert(::Type{Ptr{T}}, x::MtlArray{T}) where {T} = throw(ArgumentError("cannot take the host address of a $(typeof(x))"))
Base.unsafe_convert(::Type{Ptr{S}}, x::MtlArray{T}) where {S,T} = throw(ArgumentError("cannot take the host address of a $(typeof(x))"))

Base.unsafe_convert(t::Type{MTL.MTLBuffer}, x::MtlArray{T}) where {T}   = Base.unsafe_convert(t, pointer(x))


## interop with GPU arrays

# TODO Figure out global

function Base.convert(::Type{MtlDeviceArray{T,N,AS.Device}}, a::MtlArray{T,N}) where {T,N}
    MtlDeviceArray{T,N,AS.Device}(a.dims, reinterpret(Core.LLVMPtr{T, 1}, pointer(a).handle))
end

Adapt.adapt_storage(::Adaptor, xs::MtlArray{T,N}) where {T,N} =
  convert(MtlDeviceArray{T,N,AS.Device}, xs)

# Adapt.adapt_storage(::Adaptor, xs::MtlArray{T,N}) where {T,N} =
#   convert(Core.LLVMPtr{T,AS.Device}, xs)

function Base.convert(::Type{Core.LLVMPtr{T,AS.Device}}, a::MtlArray{T}) where {T}
    reinterpret(Core.LLVMPtr{T, 1}, a.buffer.handle)
end
## interop with CPU arrays

Base.unsafe_wrap(t::Type{<:Array}, arr::MtlArray, dims; own=false) = unsafe_wrap(t, arr.buffer, dims; own=own)

# We don't convert isbits types in `adapt`, since they are already
# considered GPU-compatible.

Adapt.adapt_storage(::Type{MtlArray}, xs::AbstractArray) =
  isbits(xs) ? xs : convert(MtlArray, xs)

# if an element type is specified, convert to it
Adapt.adapt_storage(::Type{<:MtlArray{T}}, xs::AbstractArray) where {T} =
  isbits(xs) ? xs : convert(MtlArray{T}, xs)

Adapt.adapt_storage(::Type{Array}, xs::MtlArray) = convert(Array, xs)

Base.collect(x::MtlArray{T,N}) where {T,N} = copyto!(Array{T,N}(undef, size(x)), x)

function Base.copyto!(dest::MtlArray{T}, doffs::Integer, src::Array{T}, soffs::Integer,
                      n::Integer) where T
  n==0 && return dest
  @boundscheck checkbounds(dest, doffs)
  @boundscheck checkbounds(dest, doffs+n-1)
  @boundscheck checkbounds(src, soffs)
  @boundscheck checkbounds(src, soffs+n-1)
  unsafe_copyto!(dest.dev, dest, doffs, src, soffs, n)
  return dest
end

Base.copyto!(dest::MtlArray{T}, src::Array{T}) where {T} =
    copyto!(dest, 1, src, 1, length(src))

function Base.copyto!(dest::Array{T}, doffs::Integer, src::MtlArray{T}, soffs::Integer,
                      n::Integer) where T
  n==0 && return dest
  @boundscheck checkbounds(dest, doffs)
  @boundscheck checkbounds(dest, doffs+n-1)
  @boundscheck checkbounds(src, soffs)
  @boundscheck checkbounds(src, soffs+n-1)
  unsafe_copyto!(src.dev, dest, doffs, src, soffs, n)
  return dest
end

Base.copyto!(dest::Array{T}, src::MtlArray{T}) where {T} =
    copyto!(dest, 1, src, 1, length(src))

function Base.copyto!(dest::MtlArray{T}, doffs::Integer, src::MtlArray{T}, soffs::Integer,
                      n::Integer) where T
  n==0 && return dest
  @boundscheck checkbounds(dest, doffs)
  @boundscheck checkbounds(dest, doffs+n-1)
  @boundscheck checkbounds(src, soffs)
  @boundscheck checkbounds(src, soffs+n-1)
  # TODO: which device to use here?
  if dest.dev == src.dev
    unsafe_copyto!(dest.dev, dest, doffs, src, soffs, n)
  else
    error("Copy between different devices not implemented")
  end
  return dest
end

Base.copyto!(dest::MtlArray{T}, src::MtlArray{T}) where {T} =
    copyto!(dest, 1, src, 1, length(src))

function Base.unsafe_copyto!(dev::MtlDevice, dest::MtlArray{T}, doffs, src::Array{T}, soffs, n) where T
  GC.@preserve src dest begin
    unsafe_copyto!(dev, pointer(dest), doffs, pointer(src, soffs), n)
  end
  if Base.isbitsunion(T)
    # copy selector bytes
    error("Not implemented")
  end
  return dest
end

function Base.unsafe_copyto!(dev::MtlDevice, dest::Array{T}, doff, src::MtlArray{T}, soff, n) where T
  GC.@preserve src dest begin
    unsafe_copyto!(dev, pointer(dest, doff), pointer(src), soff, n)
  end
  #GC.@preserve src dest unsafe_copyto!(dev, pointer(dest, doffs), pointer(src, soffs), n)
  if Base.isbitsunion(T)
    # copy selector bytes
    error("Not implemented")
  end
  return dest
end

function Base.unsafe_copyto!(dev::MtlDevice, dest::MtlArray{T}, doffs, src::MtlArray{T}, soffs, n) where T
  GC.@preserve src dest unsafe_copyto!(dev, pointer(dest), doffs, pointer(src), soffs, n)
#  GC.@preserve src dest unsafe_copyto!(dev, pointer(dest, doffs), pointer(src, soffs), n)
  if Base.isbitsunion(T)
    # copy selector bytes
    error("Not implemented")
  end
  return dest
end


## utilities

zeros(T::Type, dims...) = fill!(MtlArray{T}(undef, dims...), 0)
ones(T::Type, dims...) = fill!(MtlArray{T}(undef, dims...), 1)
zeros(dims...) = zeros(Float32, dims...)
ones(dims...) = Mtls(Float32, dims...)
fill(v, dims...) = fill!(MtlArray{typeof(v)}(undef, dims...), v)
fill(v, dims::Dims) = fill!(MtlArray{typeof(v)}(undef, dims...), v)

function Base.fill!(A::MtlArray{T}, val) where T
  B = convert(T, val)
  unsafe_fill!(A.dev, pointer(A), B, length(A))
  A
end

