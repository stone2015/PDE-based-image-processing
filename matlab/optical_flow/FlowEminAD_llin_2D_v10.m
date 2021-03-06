function [U V varargout] = FlowEminAD_llin_2D(Iin, channels, fstTerm, sndTerm, varargin)
%function [U V] = FlowEminAD_llin_2D(Iin, channels, fstTerm, sndTerm, varargin)
%
%Implements late linearisation optical flow calculation with anisotropic diffusion based either on flow or image.
%
%FlowEminX_Y_Z
%	X	=	HS/ND/AD (Horn&Schunk/nonlinear diffusion/anisotropic diffusion)
%	Y	=	elin/llin/ (early/late linearization) sym (symmetrical)
%	Z	=	2D/3D (2D or 3D smoothness constraint)
%
%EXAMPLE: FlowEminAD_llin_2D( Iseq, 3, 'grad', 'gradmag', 'alpha', 0.05 );
%
%Uses functions medfilt2 and imresize from Matlab Image Processing Toolbox
%
%INPUT
%Iin		=		Image secuence (concatenated i.e. cat(3,It0, It1))
%channels	=		Number of channels per image (e.g. 1 for gray, 3 for RGB)
%fstTerm	=		First constancy term: 'rgb','grad'
%sndTerm	=		Second constancy term: 'none', 'rgb', 'gradmag'
%
%OUTPUT
%U		=		Horizontal component of movement.
%V		=		Vertical component of movement.
%
%PARAMETERS
%See in the code
%
%Author: Jarno Ralli
%E-mail: jarno@ralli.fi
%Web: www.jarnoralli.fi (or www.jarnoralli.com)
%
%If you use this code, please reference (some) of my papers available at http://www.jarnoralli.fi
%
%The program is delivered as it is and the author accepts no responsibility what so ever of its use and/or results.
%Errors and suggestions are kindly to be communicated to the author.
%
%(C) Copyright 2011-2014, Jarno Ralli
%
%This program is free software: you can redistribute it and/or modify
%it under the terms of the GNU Lesser General Public License as published by
%the Free Software Foundation, either version 3 of the License, or
%(at your option) any later version.
%
%This program is distributed in the hope that it will be useful,
%but WITHOUT ANY WARRANTY; without even the implied warranty of
%MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%GNU Lesser General Public License for more details.
%
%You should have received a copy of the GNU Lesser General Public License
%along with this program.  If not, see <http://www.gnu.org/licenses/>.

%------------------------
% Get and set parameters
%------------------------
param.quantile		= 0.9;			%Quantile used for determining strength of edges used for controlling diffusion
param.diffusion 	= 'image';		%Diffusion based on 'image' or 'flow'
param.alpha 		= 0.0420;		%Smoothness weight (diffusion coefficient)
param.omega 		= 1.9;			%Relaxation parameter for SOR
param.gammaS 		= 0.01;			%Spatial apriori weight.
param.firstLoop 	= 4;			%Number of iterations, outer fixed-point loop
param.secondLoop 	= 4;			%Number of iterations, inner fixed-point loop
param.iter 		= 4;			%Number of SOR iterations (solver)
param.b1 		= 1.4843;		%Brightness constancy coefficient
param.b2 		= 0.2915;		%Gradient constancy coefficient
param.scl_factor 	= 0.75;			%Scale factor
param.solver 		= 2.0;			%Type of solver used:
						    %1 = Normal point-wise Gauss-Seidel relaxation.
						    %2 = Alternating line relaxation (ALR) - Block Gauss-Seidel.
param.Us = [];					%Spatial constraint for U.
param.Vs = [];					%Spatial constraint for V.
param.scales = double(intmax);
param = setParameters(param, varargin{:});

fstTerm = upper( fstTerm );
sndTerm = upper( sndTerm );

%Input is probably uint8 (0-255). For calculation we need 'single' (float in C).
%Given parameters work 'properly' for images scaled between 0-1.
Iin = single( Iin )./255;

USap = [];
VSap = [];
ASCu = [];
ASDu = [];
gSu = [];
gSv = [];
ASCv = [];
ASDv = [];

M2 = [];
gD2 = [];
Cu2 = [];
Cv2 = [];
Du2 = [];
Dv2 = [];

U = [];
V = [];

%------------------------
%--- Smoothening mask ---
%------------------------
G = fspecial('gaussian',[5 5],1.25);

%-----------------------------------------
% Build image pyramid: scale input images 
%-----------------------------------------
It0{1} = Iin(:,:,1:channels);
It1{1} = Iin(:,:,channels+1:2*channels);
isizes{1} = size(It0{1});
for scl=2:param.scales
	
	It0{scl} = imresize( It0{scl-1}, param.scl_factor, 'bilinear' );
	It1{scl} = imresize( It1{scl-1}, param.scl_factor, 'bilinear' );
	isizes{scl} = size(It0{scl});
	%----------
	% Smoothen
	%----------
	It0{scl-1} = imfilter( It0{scl-1}, G, 'replicate' );
	It1{scl-1} = imfilter( It1{scl-1}, G, 'replicate' );
	%If scaled image size is less than 10, break
	if isizes{scl}(1)<=20 | isizes{scl}(2)<=20
		param.scales = scl;
		%---------------------
		% Smoothen last scale
		%---------------------
		It0{scl} = imfilter( It0{scl}, G, 'replicate' );
		It1{scl} = imfilter( It1{scl}, G, 'replicate' );
		break
	end
end

%----------------------
% First constancy term
%----------------------
for scl=1:param.scales

	switch (fstTerm)

		case 'RGB'		%RGB constancy
			I1t0{scl} = It0{scl};
			I1t1{scl} = It1{scl};
		case 'GRAD'		%Gradient constancy
			I1t0{scl} = rgb2grad(It0{scl});
			I1t1{scl} = rgb2grad(It1{scl});
		otherwise
			error('No such fstTerm');
	end
end

%-----------------------
% Second constancy term
%-----------------------
for scl=1:param.scales

	switch (sndTerm)

		case 'NONE'		%No second term
			I2t0{scl} = [];
			I2t1{scl} = [];
		case 'RGB'		%RGB
			I2t0{scl} = It0{scl};
			I2t1{scl} = It1{scl};
		case 'GRADMAG'		%Gradient magnitude constancy (based on the first term)
			I2t0{scl} = It0{scl};
			I2t1{scl} = It1{scl};
		otherwise
			error('No such sndTerm');
	end
end

%-------------------------------------------
% Scale spatial apriori information of the solution
%-------------------------------------------
if ~isempty(param.Us)
	param.Us( isnan(param.Us) ) = 0;
	USap{1} = param.Us;

	for scl=2:param.scales
		USap{scl} = imresize( USap{scl-1}.*param.scl_factor, param.scl_factor, 'bilinear' );
	end

	U = USap{param.scales};
end
if ~isempty(param.Vs)
	param.Vs( isnan(param.Vs) ) = 0;
	VSap{1} = param.Vs;

	for scl=2:param.scales
		VSap{scl} = imresize( VSap{scl-1}.*param.scl_factor, param.scl_factor, 'bilinear' );
	end

	V = VSap{param.scales};
end

%----------------------------
% Multiscale, coarse to fine
%----------------------------
for scl=param.scales:-1:1
	
	ASdiff = 2*(1/param.scl_factor)^-(scl-1);
	
	[rows cols channels1]	= size( I1t1{scl} );
	[rows2 cols2 channels2] = size( I2t1{scl} );
	
	[X Y] = meshgrid(1:cols,1:rows);
	I1t1w = [];
	I2t1w = [];

	%-------------------
	% Diffusion weights
	%-------------------
	switch lower(param.diffusion)
		case 'image'
			[wW wNW wN wNE wE wSE wS wSW] = ADdiffWeights( It0{scl}, param.quantile );
		case 'flow'
			%Do nothing
		otherwise
			error('No such diffusion method!')
	end

	%--------------------------------
	% Initial guess is "zero flow"
	%--------------------------------
	if isempty(U)
		U = zeros( rows, cols );
		V = zeros( rows, cols );
	end

	%-----------------------
	% First iteration loop
	%-----------------------
	for firstLoop=1:param.firstLoop
	
		%-------------------------
		% Warp 1st constancy term
		%-------------------------
		I1t1w = BilinInterp_2d( single(I1t1{scl}), single(X+U), single(Y+V) );

		%-------------------------
		% Warp 2nd constancy term
		%-------------------------
		if( ~isempty(I2t1{scl}) )
			I2t1w = BilinInterp_2d( single(I2t1{scl}), single(X+U), single(Y+V) );
		end

		%------------------------------------------
		% Calculate 1st constancy term derivatives
		%------------------------------------------
		[I1dt I1dx I1dy] = FstDerivatives5( single(I1t0{scl}), single(I1t1w) );
		M1 = I1dy.*I1dx; 
		Cu1 = I1dt.*I1dx;
		Cv1 = I1dt.*I1dy;
		Du1 = I1dx.*I1dx;
		Dv1 = I1dy.*I1dy;

		%------------------------------------------
		% Calculate 2nd constancy term derivatives
		%------------------------------------------
		if( ~isempty(I2t1{scl}) )
			if( ~strcmp(sndTerm,'GRADMAG') )
				[I2dt I2dx I2dy] = FstDerivatives5( single(I2t0{scl}), single(I2t1w) );
				M2 = I2dy.*I2dx;
				Cu2 = I2dt.*I2dx;
				Cv2 = I2dt.*I2dy;
				Du2 = I2dx.*I2dx;
				Dv2 = I2dy.*I2dy;
			else
				[I2dxt I2dyt I2dxx I2dyy I2dxy] = SndDerivatives5( single(I2t0{scl}),single(I2t1w) );
				M2 = I2dxy.*( I2dxx + I2dyy );
				Cu2 = (I2dxt.*I2dxx + I2dyt.*I2dxy);
				Cv2 = (I2dxt.*I2dxy + I2dyt.*I2dyy);
				Du2 = (I2dxx.*I2dxx + I2dxy.*I2dxy);
				Dv2 = (I2dxy.*I2dxy + I2dyy.*I2dyy);
			end
		end

		%Terms from spatial apriori
		if ~isempty(USap)		
			ASCu = (USap{scl}-U);
			ASDu = 1;
		end
		if ~isempty(VSap)		
			ASCv = (VSap{scl}-V);
			ASDv = 1;
		end
		
		dU = zeros( rows, cols );
		dV = zeros( rows, cols );

		%-----------------------
		% Second iteration loop
		%-----------------------
		for secondLoop=1:param.secondLoop

			dU1rep = repmat(dU,[1 1 channels1]);
			dV1rep = repmat(dV,[1 1 channels1]);
			dU2rep = repmat(dU,[1 1 channels2]);
			dV2rep = repmat(dV,[1 1 channels2]);

			%----------------------------------------------------------
			% Non-quadratic "robust" functions (for outlier rejection)
			%----------------------------------------------------------
			%First constancy term
			OPnorm = (I1dt - I1dx.*dU1rep - I1dy.*dV1rep ).^2;
			gD1 = param.b1./(param.alpha*sqrt(OPnorm+0.00001));
			%Second constancy term
			if( ~isempty(I2t1{scl}) )
				if( ~strcmp(sndTerm,'GRADMAG') )
					OPnorm = 	(I2dt - I2dx.*dU2rep - I2dy.*dV2rep).^2;
				else
					OPnorm =	(I2dxt - I2dxx.*dU2rep - I2dxy.*dV2rep).^2 + ...
							(I2dyt - I2dxy.*dU2rep - I2dyy.*dV2rep).^2;
				end
				gD2 = param.b2./(param.alpha*sqrt(OPnorm+0.00001));
			end

			%Spatial apriori term
			if ~isempty(USap)
				%----------------------------------------------
				% gSu => spatial apriori term: "influence function"
				%----------------------------------------------
				APUnorm = (USap{scl}-U-dU).^2;
				gSu = (param.gammaS)./(param.alpha*(1 + APUnorm/(ASdiff.^2)));
			end
			if ~isempty(VSap)
				%----------------------------------------------
				% gSv => spatial apriori term: "influence function"
				%----------------------------------------------
				APVnorm = (VSap{scl}-V-dV).^2;
				gSv = (param.gammaS)./(param.alpha*(1 + APVnorm/(ASdiff.^2)));
			end
	
			%-------------------
			% Diffusion weights
			%-------------------
			switch lower(param.diffusion)
				case 'image'
					%Do nothing
				case 'flow'
					[wW wNW wN wNE wE wSE wS wSW] = ADdiffWeights( U+dU+V+dV, param.quantile );
				otherwise
					error('No such diffusion method!')
			end

			MGd = nansum( cat(3, M1.*gD1, M2.*gD2), 3);
			CuGd = nansum( cat(3,Cu1.*gD1, Cu2.*gD2, ASCu.*gSu),3 );
			DuGd = nansum( cat(3,Du1.*gD1, Du2.*gD2, ASDu.*gSu),3 );
			CvGd = nansum( cat(3,Cv1.*gD1, Cv2.*gD2, ASCv.*gSv),3 );
			DvGd = nansum( cat(3,Dv1.*gD1, Dv2.*gD2, ASDv.*gSv),3 );
			
			%--------
			% Solver
			%--------
			[dU dV] = Oflow_sor_llin8_2d(	single(U), ...
							single(V), ...
							single(dU), ...
							single(dV), ...
							single(MGd), ...
							single(CuGd), ...
							single(CvGd), ...
							single(DuGd), ...
							single(DvGd), ...
							single(wW), ...
							single(wNW), ...
							single(wN), ...
							single(wNE), ...
							single(wE), ...
							single(wSE), ...
							single(wS), ...
							single(wSW), ...
							single(param.iter), ...
							single(param.omega), ...
							single(param.solver) ...
						);

		end
		%-------------------
		% End of second loop
		%-------------------
		U = medfilt2( U + dU, [3 3], 'symmetric' );	
		V = medfilt2( V + dV, [3 3], 'symmetric' );
	end 
	%-------------------
	% End of first loop
	%-------------------

	%--------------
	% Upscale flow
	%--------------
	if (scl-1)>0
		U = imresize( U.*(1/param.scl_factor), 'OutputSize', isizes{scl-1}(1:2), 'Method', 'triangle'  );
		V = imresize( V.*(1/param.scl_factor), 'OutputSize', isizes{scl-1}(1:2), 'Method', 'triangle'  );
	end

end

%---------------------------------------
%--- rgb2grad: rgb to gradient
%---------------------------------------
function OUT=rgb2grad( IN )

	[rows cols frames] = size(IN);

	Odx = [1 0 -1];
	Ody = Odx';

	for i=1:frames
	    OUT(:,:,i*2-1) = imfilter( IN(:,:,i), Odx, 'replicate' );
	    OUT(:,:,i*2) = imfilter( IN(:,:,i), Ody, 'replicate' );
	end

%----------------------------------
%--- Anisotropic diffusion weights
%----------------------------------
function [W NW N NE E SE S SW] = ADdiffWeights(D, quantile)
%function [W NW N NE E SE S SW] = ADdiffWeights(D, quantile)
%
%Calculates anisotropic diffusion weights between pixels. 
%Quantile controls the strength of edges that are considered important. Value should be between 0 and 1.
%
%Diffusion tensor is based on the following equation:
%T(dI) = 1/(||dI||^2+2*lambda^2)    *   [ ( (dI/dy)^2 + lambda^2 )  -( dI/dx*dI/dy );
%                                        -( dI/dx*dI/dy )            ( (dI/dx)^2 + lambda^2 )]
%where the output is marked as:
%T(dI) = [dyy -dxy;-dxy dxx]

%--------------------
% Derivation kernels 
%--------------------
%Alvarez derivative operators
O_dx =[ 1           0   -1;
	sqrt(2)     0   -sqrt(2);
	1           0   -1]./(4+sqrt(8));
O_dy =[	1   sqrt(2)     1;
	0   0           0;
	-1   -sqrt(2)     -1]./(4+sqrt(8));

D = double(D);

[rows cols frames] = size(D);

%Calculate derivatives
Dx = imfilter( D, O_dx, 'replicate', 'conv' );
Dy = imfilter( D, O_dy, 'replicate', 'conv' );

if frames>1
	%Calculate gradient norm
	[Mval Mind] = max( (Dx.^2 + Dy.^2), [], 3 );
	[X Y] = meshgrid( 1:cols, 1:rows );
	indices_from = sub2ind( [rows cols frames], Y, X, Mind );
		
	maxDx = Dx(indices_from);
	maxDy = Dy(indices_from);
else
	maxDx = Dx;
	maxDy = Dy;
end
	
normDxDy = maxDx.^2 + maxDy.^2;

%Choose lambda adaptively
normDxDy_sorted = normDxDy(:);
normDxDy_sorted(normDxDy_sorted==0) = [];
normDxDy_sorted = sort( normDxDy_sorted );

if ~isempty(normDxDy_sorted)
	lambda = normDxDy_sorted( round(numel(normDxDy_sorted)*quantile) );
else
	lambda = 1;
end

%Multiplicator
multip = 1./( (normDxDy) + 2*lambda );
%Diffusion tensor components
dyy = multip.*( maxDy.^2 + lambda );
dxx = multip.*( maxDx.^2 + lambda );
dxy = -multip.*( maxDx.*maxDy );

W =	0.5*(	dyy + circshift(dyy,[0 1]) );
NW =	0.25*(	dxy + circshift(dxy,[1 1]) );
N =	0.5*(	dxx + circshift(dxx,[1 0]) );
NE =	-0.25*(	dxy + circshift(dxy,[1 -1]) );
E =	0.5*(	dyy + circshift(dyy,[0 -1]) );
SE =	0.25*(	dxy + circshift(dxy,[-1 -1]) );
S =	0.5*(	dxx + circshift(dxx,[-1 0]) );
SW =	-0.25*(	dxy + circshift(dxy,[-1 1]) );

