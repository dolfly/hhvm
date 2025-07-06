/*
 *  Copyright (c) 2018-present, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree.
 */

#include <fizz/crypto/aead/IOBufUtil.h>
#include <fizz/record/EncryptedRecordLayer.h>
#include <fizz/record/RecordLayerUtils.h>

namespace fizz {

using ContentTypeType = typename std::underlying_type<ContentType>::type;
using ProtocolVersionType =
    typename std::underlying_type<ProtocolVersion>::type;

static constexpr size_t kEncryptedHeaderSize =
    sizeof(ContentType) + sizeof(ProtocolVersion) + sizeof(uint16_t);

EncryptedReadRecordLayer::ReadResult<Buf>
EncryptedReadRecordLayer::getDecryptedBuf(
    folly::IOBufQueue& buf,
    Aead::AeadOptions options) {
  while (true) {
    // Check if we have enough data for the header
    if (buf.chainLength() < kEncryptedHeaderSize) {
      return ReadResult<Buf>::noneWithSizeHint(
          kEncryptedHeaderSize - buf.chainLength());
    }

    // We have the header, check if we have enough data for the full record
    folly::io::Cursor cursor(buf.front());
    cursor.skip(3); // Skip content type and protocol version
    auto length = cursor.readBE<uint16_t>();

    // Check if the record is too large
    if (length > kMaxEncryptedRecordSize) {
      throw std::runtime_error("received too long encrypted record");
    }

    // Calculate how many more bytes we need
    auto consumedBytes = cursor - buf.front();
    if (buf.chainLength() < consumedBytes + length) {
      auto remaining = (consumedBytes + length) - buf.chainLength();
      return ReadResult<Buf>::noneWithSizeHint(remaining);
    }

    // Now we have enough data, parse the record
    auto parsedRecord = RecordLayerUtils::parseEncryptedRecord(buf);

    // If this is a change_cipher_spec record, continue to the next record
    if (parsedRecord.continueReading) {
      continue;
    }

    // Check sequence number limit
    if (seqNum_ == std::numeric_limits<uint64_t>::max()) {
      throw std::runtime_error("max read seq num");
    }

    // Handle decryption with support for skipping failed decryption
    if (skipFailedDecryption_) {
      auto decryptAttempt = aead_->tryDecrypt(
          std::move(parsedRecord.ciphertext),
          useAdditionalData_ ? parsedRecord.header.get() : nullptr,
          seqNum_,
          options);
      if (decryptAttempt) {
        seqNum_++;
        skipFailedDecryption_ = false;
        return ReadResult<Buf>::from(std::move(decryptAttempt).value());
      } else {
        continue;
      }
    } else {
      return ReadResult<Buf>::from(aead_->decrypt(
          std::move(parsedRecord.ciphertext),
          useAdditionalData_ ? parsedRecord.header.get() : nullptr,
          seqNum_++,
          options));
    }
  }
}

EncryptedReadRecordLayer::ReadResult<TLSMessage> EncryptedReadRecordLayer::read(
    folly::IOBufQueue& buf,
    Aead::AeadOptions options) {
  auto decryptedBuf = getDecryptedBuf(buf, std::move(options));
  if (!decryptedBuf) {
    return ReadResult<TLSMessage>::noneWithSizeHint(decryptedBuf.sizeHint);
  }

  TLSMessage msg{};
  // Use the utility function to parse and remove content type
  auto maybeContentType =
      RecordLayerUtils::parseAndRemoveContentType(*decryptedBuf);
  if (!maybeContentType) {
    throw std::runtime_error("No content type found");
  }
  msg.type = *maybeContentType;
  msg.fragment = std::move(*decryptedBuf);

  switch (msg.type) {
    case ContentType::handshake:
    case ContentType::alert:
    case ContentType::application_data:
      break;
    default:
      throw std::runtime_error(folly::to<std::string>(
          "received encrypted content type ",
          static_cast<ContentTypeType>(msg.type)));
  }

  if (!msg.fragment || msg.fragment->empty()) {
    if (msg.type == ContentType::application_data) {
      msg.fragment = folly::IOBuf::create(0);
    } else {
      throw std::runtime_error("received empty fragment");
    }
  }

  return ReadResult<TLSMessage>::from(std::move(msg));
}

EncryptionLevel EncryptedReadRecordLayer::getEncryptionLevel() const {
  return encryptionLevel_;
}

TLSContent EncryptedWriteRecordLayer::write(
    TLSMessage&& msg,
    Aead::AeadOptions options) const {
  folly::IOBufQueue queue;
  queue.append(std::move(msg.fragment));
  std::unique_ptr<folly::IOBuf> outBuf;
  std::array<uint8_t, RecordLayerUtils::kEncryptedHeaderSize> headerBuf{};
  auto header = folly::IOBuf::wrapBufferAsValue(folly::range(headerBuf));
  aead_->setEncryptedBufferHeadroom(RecordLayerUtils::kEncryptedHeaderSize);

  while (!queue.empty()) {
    if (seqNum_ == std::numeric_limits<uint64_t>::max()) {
      throw std::runtime_error("max write seq num");
    }
    // Use the helper function to prepare the buffer with padding
    auto dataBuf = prepareBufferWithPadding(
        queue, msg.type, *bufAndPaddingPolicy_, maxRecord_, aead_.get());

    // we will either be able to memcpy directly into the ciphertext or
    // need to create a new buf to insert before the ciphertext but we need
    // it for additional data
    header.clear();
    folly::io::Appender appender(&header, 0);
    appender.writeBE(
        static_cast<ContentTypeType>(ContentType::application_data));
    appender.writeBE(
        static_cast<ProtocolVersionType>(ProtocolVersion::tls_1_2));
    auto ciphertextLength =
        dataBuf->computeChainDataLength() + aead_->getCipherOverhead();
    appender.writeBE<uint16_t>(ciphertextLength);

    auto recordBuf = RecordLayerUtils::writeEncryptedRecord(
        std::move(dataBuf),
        aead_.get(),
        &header,
        useAdditionalData_ ? &header : nullptr,
        seqNum_++,
        options);

    if (!outBuf) {
      outBuf = std::move(recordBuf);
    } else {
      outBuf->prependChain(std::move(recordBuf));
    }
  }

  if (!outBuf) {
    outBuf = folly::IOBuf::create(0);
  }

  TLSContent content;
  content.data = std::move(outBuf);
  content.contentType = msg.type;
  content.encryptionLevel = encryptionLevel_;
  return content;
}

EncryptionLevel EncryptedWriteRecordLayer::getEncryptionLevel() const {
  return encryptionLevel_;
}
} // namespace fizz
