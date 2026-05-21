package main

import (
	"bytes"
	"fmt"
	"log"

	flowpb "github.com/netsampler/goflow2/v3/pb"
	"google.golang.org/protobuf/encoding/protodelim"
	"google.golang.org/protobuf/proto"
)

func main() {
	// Create a minimal FlowMessage
	msg := &flowpb.FlowMessage{
		TimeReceivedNs: 123456789,
		SrcAddr:        []byte{192, 168, 1, 1},
		DstAddr:        []byte{192, 168, 1, 2},
		SrcPort:        12345,
		DstPort:        80,
		Proto:          6, // TCP
		Bytes:          1000,
		Packets:        10,
	}

	// Test 1: Marshal with delimiter (as binary format does by default)
	buf1 := bytes.NewBuffer(nil)
	_, err := protodelim.MarshalTo(buf1, msg)
	if err != nil {
		log.Fatal("protodelim.MarshalTo failed:", err)
	}
	data1 := buf1.Bytes()
	fmt.Printf("Delimited protobuf length: %d, hex: %x\n", len(data1), data1[:min(32, len(data1))])

	// Test 2: Marshal without delimiter (skipDelimiter = true)
	data2, err := proto.Marshal(msg)
	if err != nil {
		log.Fatal("proto.Marshal failed:", err)
	}
	fmt.Printf("Raw protobuf length: %d, hex: %x\n", len(data2), data2[:min(32, len(data2))])

	// Test decoding with our logic
	testDecode := func(data []byte, desc string) {
		fmt.Printf("\n--- Testing %s ---\n", desc)
		reader := bytes.NewReader(data)
		decoded := &flowpb.FlowMessage{}
		if err := protodelim.UnmarshalFrom(reader, decoded); err != nil {
			fmt.Printf("protodelim.UnmarshalFrom failed: %v\n", err)
			// fallback
			if err := proto.Unmarshal(data, decoded); err != nil {
				fmt.Printf("proto.Unmarshal also failed: %v\n", err)
				return
			}
			fmt.Println("Fallback proto.Unmarshal succeeded")
		} else {
			fmt.Println("protodelim.UnmarshalFrom succeeded")
		}
		// Verify some fields
		if decoded.TimeReceivedNs == msg.TimeReceivedNs &&
			bytes.Equal(decoded.SrcAddr, msg.SrcAddr) &&
			bytes.Equal(decoded.DstAddr, msg.DstAddr) {
			fmt.Println("Fields match")
		} else {
			fmt.Println("Fields mismatch")
		}
	}

	testDecode(data1, "delimited protobuf")
	testDecode(data2, "raw protobuf")
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
