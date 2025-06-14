// Name: FXAA
// Author: Thomas Schneider
// Description: FXAA for Virtualdub

//VDub and HLSL in general cannot use >for< loops, Nvidia replaced them with nested ifs
//Sources:
//- Reshade 3.0 (https://github.com/crosire/reshade)
//- ^contains FXAA 3.11 from Nvidia
//- https://blog.simonrodriguez.fr/articles/2016/07/implementing_fxaa.html

//Notes: virutaldub knows no preprocessor, they must be condensed manually with following settings:
//Standard setting of Preset 15 should be good enoguh
//define FXAA_QUALITY__PRESET 15
//define FXAA_GREEN_AS_LUMA 0
//define FXAA_LINEAR_LIGHT 0
//define FXAA_GATHER4_ALPHA 0
//define FXAA_PC 1
//define FXAA_HLSL_3 1
//define FXAA_EARLY_EXIT 1

texture vd_srctexture;

float4 vd_texsize;

sampler src = sampler_state {
	texture = (vd_srctexture);
};

float SubPixel <
	bool vd_tunable = true;
	float vd_tunablemin = 0;
	float vd_tunablemax = 1;
	float vd_tunablesteps = 40;
> = 0.25;

float EdgeThreshold <
	bool vd_tunable = true;
	float vd_tunablemin = 0;
	float vd_tunablemax = 1;
	float vd_tunablesteps = 40;
> = 0.125;

float EdgeThresholdMin <
	bool vd_tunable = true;
	float vd_tunablemin = 0;
	float vd_tunablemax = 1;
	float vd_tunablesteps = 40;
> = 0;

float Tex2Luma(float2 uv : TEXCOORD0, float2 OfSt) {
	float2 P = float2(uv.xy);//0.9999;	
	float2 PxSz = 1.0/float2 (vd_texsize.xy); 
	float3 Luma = float3 (0.299, 0.587, 0.114);
	return (dot(tex2D(src,P+OfSt*PxSz).rgb,Luma)) ;
}

float4 FXAA(float2 uv : TEXCOORD0) : COLOR0 {
	float2 PosCenter = float2 (uv.xy);//0.9999;	
	float2 PxSz = 1.0/float2(vd_texsize.xy);
	float3 FinalColor;
	
	// Luma at the current fragment
	float LumaCenter    = Tex2Luma(PosCenter, float2( 0, 0));
	
	// Luma at the four direct neighbours of the current fragment.
	float LumaDown      = Tex2Luma(PosCenter, float2( 0,-1));
	float LumaUp        = Tex2Luma(PosCenter, float2( 0, 1));
	float LumaLeft      = Tex2Luma(PosCenter, float2(-1, 0));
	float LumaRight     = Tex2Luma(PosCenter, float2( 1, 0));
	
	float LumaDownLeft  = Tex2Luma(PosCenter, float2(-1,-1));
	float LumaUpRight   = Tex2Luma(PosCenter, float2( 1, 1));
	float LumaUpLeft    = Tex2Luma(PosCenter, float2(-1, 1));
	float LumaDownRight = Tex2Luma(PosCenter, float2( 1,-1));
	
	// Find the maximum and minimum luma around the current fragment.
	float LumaMin = min(LumaCenter,min(min(LumaDown,LumaUp),min(LumaLeft,LumaRight)));
	float LumaMax = max(LumaCenter,max(max(LumaDown,LumaUp),max(LumaLeft,LumaRight)));
	
	// Calculate the delta
	float LumaRange = LumaMax - LumaMin;
	
	// Early exit at low luma not possible in VDup via return. We can skip modifying pixels but not reduce computation.
	bool EarlyExit = LumaRange <  max(EdgeThresholdMin,LumaMax*EdgeThreshold);
	if(EarlyExit) {
		FinalColor = tex2D(src,PosCenter).rgb;
	} else { 

		// Combine the four edges luma (using intermediary variables for future computations with the same values).
		float LumaDownUp = LumaDown + LumaUp;
		float LumaLeftRight = LumaLeft + LumaRight;
	
		// Same for corners
		float LumaLeftCorners = LumaDownLeft + LumaUpLeft;
		float LumaDownCorners = LumaDownLeft + LumaDownRight;
		float LumaRightCorners = LumaDownRight + LumaUpRight;
		float LumaUpCorners = LumaUpRight + LumaUpLeft;
	
		// Compute an estimation of the gradient along the horizontal and vertical axis.
		float EdgeHorizontal = abs(-2.0 * LumaLeft + LumaLeftCorners)  
							 + abs(-2.0 * LumaCenter + LumaDownUp ) * 2.0    
							 + abs(-2.0 * LumaRight + LumaRightCorners);
		float EdgeVertical   = abs(-2.0 * LumaUp + LumaUpCorners)      
							 + abs(-2.0 * LumaCenter + LumaLeftRight) * 2.0  
							 + abs(-2.0 * LumaDown + LumaDownCorners);
	
		// Is the local edge horizontal or vertical ?
		bool IsHorizontal = (EdgeHorizontal >= EdgeVertical);
	
		// Select the two neighboring texels lumas in the opposite direction to the local edge.
		float Luma1 = IsHorizontal ? LumaDown : LumaLeft;
		float Luma2 = IsHorizontal ? LumaUp : LumaRight;
		// Compute gradients in this direction.
		float Gradient1 = Luma1 - LumaCenter;
		float Gradient2 = Luma2 - LumaCenter;
	
		// Which direction is the steepest ?
		bool Is1Steepest = abs(Gradient1) >= abs(Gradient2);
	
		// Gradient in the corresponding direction, normalized.
		float GradientScaled = 0.25*max(abs(Gradient1),abs(Gradient2));
	
	    // Choose the step size (one pixel) according to the edge direction.
		float StepLength = IsHorizontal ? PxSz.y : PxSz.x;
	
		// Average luma in the correct direction.
		float LumaLocalAverage;
	
		if(Is1Steepest){
			// Switch the direction
			StepLength = - StepLength;
			LumaLocalAverage = 0.5*(Luma1 + LumaCenter);
		} else {
			LumaLocalAverage = 0.5*(Luma2 + LumaCenter);
		}
	
		// Shift UV in the correct direction by half a pixel.
		float2 Pos0 = PosCenter;
		if(IsHorizontal){			//Shift coord a haslf pixel towards edge
			Pos0 += float2 (0,StepLength/2);
		} else {
			Pos0 += float2 (StepLength/2,0);
		}
		
		// Compute offset (for each iteration step) in the right direction => one pixel sideways on edge
		float2 Offset = IsHorizontal ? float2 (PxSz.x,0) : float2(0,PxSz.y);
		
		// I needed to inverse the logic, as VDub does not know "!Done" like used by nvidia and using "Done==0" crashes compiler.
		// The clearer logic showed me a more simple implenetation. Let's separate .1 and .2 to save some ifs
		
		// Compute UVs to explore on each side of the edge, orthogonally. 
		//FXAA_QUALITY__P0 = 1.0
		float2 Pos1 = Pos0 - Offset; //*1.0
		float LumaEnd1 = Tex2Luma(Pos1, float2(0,0)) - LumaLocalAverage;    
	    bool Search1 = abs(LumaEnd1) < GradientScaled; //= DoneN ... >=
	    
		//FXAA_QUALITY__P1 = 1.5
	    if (Search1) { //NV uses DoneNP? but it means the opposite - brainfuck!
			Pos1 -= Offset * 1.5;
			LumaEnd1 = Tex2Luma(Pos1, float2(0,0)) - LumaLocalAverage;    
	    	Search1 = abs(LumaEnd1) < GradientScaled;
	
			//FXAA_QUALITY__P2 = 2.0
			if(Search1) {
				Pos1 -= Offset * 2.0; //FXAA_QUALITY__P2;
				LumaEnd1 = Tex2Luma(Pos1, float2(0,0)) - LumaLocalAverage; 
				Search1 = abs(LumaEnd1) < GradientScaled;
				
				//FXAA_QUALITY__P3 = 2.0
				if(Search1) {
					Pos1 -= Offset * 2.0; //FXAA_QUALITY__P3;
					LumaEnd1 = Tex2Luma(Pos1, float2(0,0)) - LumaLocalAverage; 
					Search1 = abs(LumaEnd1) < GradientScaled;
					
					//FXAA_QUALITY__P4 = 2.0
					if(Search1) {
						Pos1 -= Offset * 2.0; //FXAA_QUALITY__P4;
						LumaEnd1 = Tex2Luma(Pos1, float2(0,0)) - LumaLocalAverage; 
						Search1 = abs(LumaEnd1) < GradientScaled;
						
						//FXAA_QUALITY__P6 = 4.0
						if(Search1) {
							Pos1 -= Offset * 2.0; //FXAA_QUALITY__P5;
							LumaEnd1 = Tex2Luma(Pos1, float2(0,0)) - LumaLocalAverage; 
							Search1 = abs(LumaEnd1) < GradientScaled;
							
							//FXAA_QUALITY__P7 = 12.0
							if(Search1) {
								Pos1 -= Offset * 4.0; //FXAA_QUALITY__P6;
								LumaEnd1 = Tex2Luma(Pos1, float2(0,0)) - LumaLocalAverage; 
								Search1 = abs(LumaEnd1) < GradientScaled;
								
								//FXAA_QUALITY__P7 = 12.0
								if(Search1) Pos1 -= Offset * 12.0; //FXAA_QUALITY__P7;
								// Nothing to probe anymore, we end here	
							}
						}
					}
				}
			}
		}
	
		// The same in the opposite direction:
	    float2 Pos2 = Pos0 + Offset; 
		float LumaEnd2 = Tex2Luma(Pos2, float2(0,0)) - LumaLocalAverage;    
	    bool Search2 = abs(LumaEnd2) < GradientScaled;
		if(Search2) {
			Pos2 += Offset * 1.5;
			LumaEnd2 = Tex2Luma(Pos2, float2(0,0)) - LumaLocalAverage;    
	    	Search2 = abs(LumaEnd2) < GradientScaled;
			if(Search2) {
				Pos2 += Offset * 2.0; 
				LumaEnd2 = Tex2Luma(Pos2, float2(0,0)) - LumaLocalAverage; 
				Search2 = abs(LumaEnd2) < GradientScaled;
				if(Search2) {
					Pos2 += Offset * 2.0;
					LumaEnd2 = Tex2Luma(Pos2, float2(0,0)) - LumaLocalAverage; 
					Search2 = abs(LumaEnd2) < GradientScaled;
					if(Search2) {
						Pos2 += Offset * 2.0;
						LumaEnd2 = Tex2Luma(Pos2, float2(0,0)) - LumaLocalAverage; 
						Search2 = abs(LumaEnd2) < GradientScaled;
						if(Search2) {
							Pos2 += Offset * 2.0; 
							LumaEnd2 = Tex2Luma(Pos2, float2(0,0)) - LumaLocalAverage; 
							Search1 = abs(LumaEnd2) < GradientScaled;
							if(Search2) {
								Pos2 += Offset * 4.0; 
								LumaEnd2 = Tex2Luma(Pos2, float2(0,0)) - LumaLocalAverage; 
								Search2 = abs(LumaEnd2) < GradientScaled;
								if(Search2) Pos2 += Offset * 12.0; 
							}
						}
					}
				}
			}
		}
	
		//In.uv = PosCenter
		//currentUv = Pos0
		//uv1,uv2 = Pos1, pos2
		
		// Compute the distances to each extremity of the edge.
		float Distance1 = IsHorizontal ? (PosCenter.x - Pos1.x) : (PosCenter.y - Pos1.y);
		float Distance2 = IsHorizontal ? (Pos2.x - PosCenter.x) : (Pos2.y - PosCenter.y);
		
		// In which direction is the etremity of the edge closer?
		bool IsDirection1 = Distance1 < Distance2;
		float DistanceFinal = min(Distance1, Distance2);
		
		// Length of the edge
		float EdgeLength = Distance1 + Distance2;
		
		// UV offset: read in the direction of the closest side of the edge	
		float PixelOffset = -DistanceFinal / EdgeLength + 0.5;
		
		// Is the luma at center smaller than the local average?
		bool IsLumaCenterSmaller = LumaCenter <= LumaLocalAverage;
		
		// If the luma at center is smaller than at its neighbour, the delta luma at each end should be positive (same variation).
		// (in the direction of the closer side of the edge.)
		bool CorrectVariation = ((IsDirection1 ? LumaEnd1 : LumaEnd2) < 0.0) != IsLumaCenterSmaller;
	
		// If the luma variation is incorrect, do not offset.
		float FinalOffset = CorrectVariation ? PixelOffset : 0.0;
	
		// Sub-pixel shifting
		// Full weighted average of the luma over the 3x3 neighborhood.
		float LumaAverage = (1.0/12.0) * (2.0 * (LumaDownUp + LumaLeftRight) + LumaLeftCorners + LumaRightCorners);
		// Ratio of the delta between the global average and the center luma, over the luma range in the 3x3 neighborhood.
		float SubPixelOffset1 = min(abs(LumaAverage - LumaCenter)/LumaRange,1.0); //VD know no clamp, abs() is pos so we must limit to 1.0 only
		float SubPixelOffset2 = (-2.0 * SubPixelOffset1 + 3.0) * SubPixelOffset1 * SubPixelOffset1;
		// Compute a sub-pixel offset based on this delta.
		float SubPixelOffsetFinal = SubPixelOffset2 * SubPixelOffset2 * SubPixel;
		
		// Pick the biggest of the two offsets.
		FinalOffset = max(FinalOffset,SubPixelOffsetFinal);
		
		float2 FinalPos = float2(PosCenter.x,PosCenter.y);
		if(IsHorizontal) {
			FinalPos.y += FinalOffset * StepLength;
		} else {
			FinalPos.x += FinalOffset * StepLength;
		}

		FinalColor = tex2D(src,FinalPos).rgb;
	}
	return float4 (FinalColor,1);
}	

technique {
	pass {
		PixelShader = compile ps_2_0 FXAA();
	}
}
