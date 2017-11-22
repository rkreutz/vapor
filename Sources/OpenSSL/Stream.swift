import Async
import Bits
import COpenSSL
import Dispatch
import Foundation
import libc

enum SSLSettings {
    internal static var initialized: Bool = {
        SSL_library_init()
        SSL_load_error_strings()
//        OpenSSL_add_all_ciphers()
        OPENSSL_config(nil)
        OPENSSL_add_all_algorithms_conf()
        return true
    }()
}

public final class SSLStream<ByteStream>: Async.Stream, ClosableStream 
    where ByteStream: Async.Stream, 
        ByteStream.Output == ByteBuffer, 
        ByteStream.Input == ByteBuffer, 
        ByteStream: ClosableStream 
{
    /// See OutputStream.Output
    public typealias Output = ByteBuffer
    
    /// See InputStream.Input
    public typealias Input = ByteBuffer
    
    /// The `SSL` context that manages this stream
    var ssl: UnsafeMutablePointer<SSL>?
    
    /// The `SSL` context that manages this stream
    var context: UnsafeMutablePointer<SSL_CTX>?
    
    /// The file descriptor to write to/from
    var descriptor: Int32
    
    /// The underlying TCP socket
    let socket: ByteStream
    
    /// The queue to read on
    let queue: DispatchQueue
    
    /// Keeps a strong reference to the DispatchSourceRead so it keeps reading
    var readSource: DispatchSourceRead?
    
    /// A buffer of all data that still needs to be written
    var writeQueue = [Data]()
    
    /// Keeps a strong reference to the DispatchSourceWrite so it can keep writing
    let writeSource: DispatchSourceWrite
    
    /// A buffer storing all deciphered data received from the remote
    let outputBuffer = MutableByteBuffer(start: .allocate(capacity: Int(UInt16.max)), count: Int(UInt16.max))
    
    /// Use a basic output stream to implement server output stream.
    internal var outputStream: BasicStream<Output> = .init()

    deinit {
        outputBuffer.baseAddress?.deallocate(capacity: outputBuffer.count)
    }
    
    /// Creates a new SSLStream on top of a socket
    public init(socket: ByteStream, descriptor: Int32, queue: DispatchQueue) throws {
        self.socket = socket
        self.descriptor = descriptor
        self.queue = queue
        
        self.writeSource = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        
        self.writeSource.setEventHandler {
            guard self.writeQueue.count > 0 else {
                self.writeSource.suspend()
                return
            }
            
            let data = self.writeQueue[0]
            
            data.withUnsafeBytes { (pointer: BytesPointer) in
                let buffer = UnsafeBufferPointer(start: pointer, count: data.count)
                
                do {
                    try self.write(from: buffer)
                    _ = self.writeQueue.removeFirst()
                } catch {
                    self.onError(error)
                }
            }
            
            guard self.writeQueue.count > 0 else {
                self.writeSource.suspend()
                return
            }
        }
    }
    
    /// Writes the buffer to this SSL socket
    @discardableResult
    public func write(from buffer: ByteBuffer) throws -> Int {
        guard let ssl = ssl else {
            close()
            throw Error(.noSSLContext)
        }
        
        let written = SSL_write(ssl, buffer.baseAddress, Int32(buffer.count))
        
        guard written > 0 else {
            if written == 0 {
                self.close()
                return 0
            } else {
                throw Error(.sslError(SSL_get_error(ssl, written)))
            }
        }
        
        return numericCast(written)
    }
    
    /// Reads from this SSL socket
    @discardableResult
    public func read(into buffer: MutableByteBuffer) throws -> Int {
        guard let ssl = ssl else {
            close()
            throw Error(.noSSLContext)
        }
        
        let read = SSL_read(ssl, buffer.baseAddress!, Int32(buffer.count))
        
        if read == 0 {
            self.close()
            return 0
        } else if read < 0 {
            throw Error(.sslError(SSL_get_error(ssl, read)))
        }
        
        return numericCast(read)
    }

    /// See InputStream.onInput
    public func onInput(_ input: ByteBuffer) {
        do {
            try self.write(from: input)
        } catch {
            self.onError(error)
            self.close()
        }
    }

    /// See InputStream.onError
    public func onError(_ error: Error) {
        outputStream.onError(error)
    }

    /// See OutputStream.onOutput
    public func onOutput<I>(_ input: I) where I: Async.InputStream, SSLStream.Output == I.Input {
        outputStream.onOutput(input)
    }

    /// See ClosableStream.onClose
    public func onClose(_ onClose: ClosableStream) {
        outputStream.onClose(onClose)
    }
    
    public func close() {
        guard let readSource = readSource else {
            socket.close()
            return
        }
        
        readSource.cancel()
        outputStream.close()
    }
}
