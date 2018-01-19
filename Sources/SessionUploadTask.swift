//
//  SessionUploadTask.swift
//  SMBClient
//
//  Created by Seth Faxon on 9/6/17.
//  Copyright © 2017 Filmic. All rights reserved.
//

import Foundation

import libdsm

public protocol SessionUploadTaskDelegate: class {
    func uploadTask(didFinishUploading: SessionUploadTask)
    func uploadTask(_ task: SessionUploadTask, totalBytesSent: UInt64, totalBytesExpected: UInt64)
    func uploadTask(didCompleteWithError: SessionUploadTask.SessionUploadError)
}

public class SessionUploadTask: SessionTask {
    var path: SMBPath
    var fileName: String
    var uploadExtension: String? // appending .upload to upload file name, then move
    var fromURL: URL
    var file: SMBFile?
    public weak var delegate: SessionUploadTaskDelegate?

    public init(session: SMBSession,
                delegateQueue: DispatchQueue = DispatchQueue.main,
                path: SMBPath,
                fileName: String,
                uploadExtension: String? = nil,
                fromURL url: URL,
                delegate: SessionUploadTaskDelegate? = nil) {
        self.path = path
        self.fileName = fileName
        self.uploadExtension = uploadExtension
        self.fromURL = url
        self.delegate = delegate
        super.init(session: session, delegateQueue: delegateQueue)
    }

    override func performTaskWith(operation: BlockOperation) {
        let chunkSize = 63488
        
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: self.fromURL)
        } catch {
            delegateError(.fileNotFound)
            return
        }
        
        if operation.isCancelled {
            delegateError(.cancelled)
            return
        }

        var treeId = smb_tid(0)
        var fileId = smb_fd(0)

        // ### connect to share
        let conn = self.session.treeConnect(volume: self.path.volume)
        switch conn {
        case .failure:
            self.delegateError(.connectionFailed)
            return
        case .success(let t):
            treeId = t
        }

        if operation.isCancelled {
            self.cleanupBlock(treeId: treeId, fileId: fileId)
        }

        // ### find the target file
        self.file = SMBFile(path: self.path, name: self.fileName)

        if operation.isCancelled {
            self.cleanupBlock(treeId: treeId, fileId: fileId)
            delegateError(.cancelled)
            return
        }

        let SMB_MOD_READ_WRITE_NEW_FILE = SMB_MOD_READ | SMB_MOD_WRITE | SMB_MOD_APPEND
            | SMB_MOD_READ_EXT | SMB_MOD_WRITE_EXT
            | SMB_MOD_READ_ATTR | SMB_MOD_WRITE_ATTR
            | SMB_MOD_READ_CTL
        let SMB_MOD_READ_WRITE_EXISTING_FILE = SMB_MOD_READ | SMB_MOD_WRITE | SMB_MOD_APPEND
            | SMB_MOD_READ_ATTR | SMB_MOD_WRITE_ATTR
            | SMB_MOD_READ_CTL

        // ### open the file handle
        guard let uploadPath = self.fileUploadPath else {
            self.delegateError(SessionUploadTask.SessionUploadError.fileNotFound)
            return
        }

        // assign file size to totalByteCount
        fileHandle.seekToEndOfFile()
        let totalByteCount = fileHandle.offsetInFile
        fileHandle.seek(toFileOffset: 0)

        var uploadBufferLimit: UInt64 = min(totalByteCount, UInt64(chunkSize))
        var bytesWritten: UInt64 = 0
        var totalBytesWritten: UInt64 = 0

        // check if there is a file to resume upload on
        if let previousUpload = self.existingTempDestination(treeId: treeId) {
            totalBytesWritten = previousUpload.fileSize
        }

        let fileOpenResult: Result<smb_fd, SMBSession.SMBSessionError>
        if totalBytesWritten == 0 {
            fileOpenResult = self.session.fileOpen(treeId: treeId, path: uploadPath, mod: UInt32(SMB_MOD_READ_WRITE_NEW_FILE))
        } else {
            fileOpenResult = self.session.fileOpen(treeId: treeId, path: uploadPath, mod: UInt32(SMB_MOD_READ_WRITE_EXISTING_FILE))
        }
        switch fileOpenResult {
        case .failure:
            self.delegateError(SessionUploadTask.SessionUploadError.connectionFailed)
            self.cleanupBlock(treeId: treeId, fileId: fileId)
            return
        case .success(let fId):
            fileId = fId
        }

        if operation.isCancelled {
            self.cleanupBlock(treeId: treeId, fileId: fileId)
            self.delegateError(.cancelled)
            return
        }

        // if resuming a previously failed upload
        if totalBytesWritten > 0 {
            let res = self.session.fileSeek(fileId: fileId, offset: UInt64(totalBytesWritten))
            switch res {
            case .success(let readPointer):
                if readPointer != totalBytesWritten {
                    // something has gone wrong, remove remote file and try again
                }
            case .failure:
                // remove file, try again
                break
            }
        }

        var buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)

        repeat {
            var remainingBytes = totalByteCount - totalBytesWritten
            if remainingBytes < uploadBufferLimit {
                uploadBufferLimit = remainingBytes
            }

            var lengthToRead: Int = min(Int(uploadBufferLimit), chunkSize)

            autoreleasepool {
                let dataBytes = fileHandle.readData(ofLength: lengthToRead)
                buffer.initialize(from: dataBytes)
            }

            bytesWritten = UInt64(self.session.fileWrite(fileId: fileId, buffer: buffer, bufferSize: lengthToRead))

            buffer.deinitialize(count: lengthToRead)

            if operation.isCancelled {
                fileHandle.closeFile()
                break
            }
            if bytesWritten < 0 {
                fail()
                self.delegateError(.uploadFailed)
                fileHandle.closeFile()
                break
            }
            self.delegateQueue.async {
                self.delegate?.uploadTask(self, totalBytesSent: totalBytesWritten, totalBytesExpected: totalByteCount)
            }

            totalBytesWritten += bytesWritten
        } while (totalBytesWritten < totalByteCount)

        buffer.deinitialize(count: chunkSize)
        buffer.deallocate(capacity: chunkSize)

        self.session.fileClose(fileId: fileId)
        fileHandle.closeFile()

        if operation.isCancelled {
            return
        }

        // if there was an upload extension move the file to remove the extension
        if self.uploadExtension != nil, let destPath = self.file?.uploadPath {
            let moveError = self.session.fileMove(volume: self.path.volume, oldPath: uploadPath, newPath: destPath)
            if moveError != nil {
                self.delegateError(.uploadFailed)
                return
            }
        }
        self.didFinish()
    }

    override public func cancel() {
        if self.state != .running {
            return
        }

        let deleteFunc = {
            if self.uploadExtension != nil, let destPath = self.file?.uploadPath {
                _ = self.session.fileDelete(volume: self.path.volume, path: destPath)
            }
            if let uploadPath = self.fileUploadPath {
                _ = self.session.fileDelete(volume: self.path.volume, path: uploadPath)
            }
        }
        let deleteOperation = BlockOperation(block: deleteFunc)
        if let op = self.taskOperation {
            deleteOperation.addDependency(op)
        }
        self.session.taskQueue.addOperation(deleteOperation)

        self.taskOperation?.cancel()
        self.state = .cancelled

        self.taskOperation = nil
    }

    private func delegateError(_ error: SessionUploadTask.SessionUploadError) {
        self.delegateQueue.async {
            self.delegate?.uploadTask(didCompleteWithError: error)
        }
    }

    private func existingTempDestination(treeId: smb_tid) -> SMBFile? {
        guard let ue = self.uploadExtension else { return nil }
        guard let filePath = self.file?.path else { return nil }
        guard let tempName = self.file?.name.appending(ue) else { return nil }
        if let tempFile = SMBFile(path: filePath, name: tempName) {
            let existingUpload = self.session.fileStat(treeId: treeId, file: tempFile)
            switch existingUpload {
            case .success(let f):
                return f
            default:
                break
            }
        }
        return nil
    }

    private var fileUploadPath: String? {
        guard let f = self.file else { return nil }
        if let ue = self.uploadExtension {
            return f.uploadPath.appending(ue)
        } else {
            return f.uploadPath
        }
    }

    private func didFinish() {
        self.state = .completed
        self.delegateQueue.async {
            self.delegate?.uploadTask(didFinishUploading: self)
        }
    }

}

extension SessionUploadTask: Equatable { }

public func == (lhs: SessionUploadTask, rhs: SessionUploadTask) -> Bool {
    return lhs.path == rhs.path
}

extension SessionUploadTask {
    public enum SessionUploadError: Error {
        case cancelled
        case connectionFailed
        case fileNotFound
        case serverNotFound
        case directoryDownloaded
        case uploadFailed
    }
}
