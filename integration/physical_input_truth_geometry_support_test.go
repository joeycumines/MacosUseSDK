// Copyright 2026 Joseph Cumines

package integration

import (
	"testing"

	typepb "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

func pointInElement(x float64, y float64, element *pb.Element) bool {
	return element != nil &&
		x >= element.GetX() &&
		x <= element.GetX()+element.GetWidth() &&
		y >= element.GetY() &&
		y <= element.GetY()+element.GetHeight()
}

func elementCenter(element *pb.Element) *typepb.Point {
	return &typepb.Point{
		X: element.GetX() + element.GetWidth()/2,
		Y: element.GetY() + element.GetHeight()/2,
	}
}

func pointMessage(point ownedDragPoint) *typepb.Point {
	return &typepb.Point{X: point.x, Y: point.y}
}

func safeDisplayPoint(frame *typepb.Region, xFraction float64, yFraction float64) *typepb.Point {
	return &typepb.Point{
		X: frame.GetX() + frame.GetWidth()*xFraction,
		Y: frame.GetY() + frame.GetHeight()*yFraction,
	}
}

func requireUniqueDisplayPoint(
	t *testing.T,
	target *pb.Display,
	displays []*pb.Display,
	preferredX float64,
	preferredY float64,
) *typepb.Point {
	t.Helper()
	fractions := [][2]float64{
		{preferredX, preferredY},
		{0.5, 0.5},
		{0.25, 0.25},
		{0.75, 0.25},
		{0.25, 0.75},
		{0.75, 0.75},
		{0.125, 0.5},
		{0.875, 0.5},
	}
	for _, fraction := range fractions {
		point := safeDisplayPoint(target.GetFrame(), fraction[0], fraction[1])
		var owners []*pb.Display
		for _, display := range displays {
			if pointInRegion(point.GetX(), point.GetY(), display.GetFrame()) {
				owners = append(owners, display)
			}
		}
		if len(owners) == 1 && owners[0].GetName() == target.GetName() {
			return point
		}
	}
	t.Fatalf(
		"display %q exposes no uniquely owned candidate point against %d active frames",
		target.GetName(),
		len(displays),
	)
	return nil
}
