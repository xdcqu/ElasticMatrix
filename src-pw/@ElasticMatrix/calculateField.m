function [fields, obj] = calculateField(obj, freqChoice, angleChoice, varargin)
    %% displacementField v1 date:  2019-01-15
    % 
    %   Author
    %   Danny Ramasawmy
    %   rmapdrr@ucl.ac.uk
    %
    %   Description
    %       Calculates the displacement field at angle (angleChoice) and
    %       frequency (freqChoice); First layer cannot be a 'vacuum' and
    %       the input arguments must be an angle and frequency. The code
    %       will be updated in the future to accept phasevelocity and
    %       wavenumber input arguments.
    %
    % inputs:
    %   (angle, frequency, {vector-Z, vector-X}, time )
    %
    %   FUTURE 
    %   - add an optional phasespeed input argument 
    %
    % =====================================================================
    %   CHECK THE INUTS
    % =====================================================================
    % currently the only be calculate over an angle and frequency - this
    % will be updated to a phase velocity in the future
    
    % error checking
    if strcmp(obj.medium(1).state,'Vacuum')
        warning('The first layer cannot currently be a vacuum.')
        fields = NaN;
        return;
    end
    
    if strcmp(obj.medium(1).state,'Gas')
        warning('The first layer cannot currently be a gas.')
        fields = NaN;
        return;
    end
    
    if isempty(obj.frequency) || isempty(obj.angle)
        warning('Please set an angle and frequency using .setAngle, .setFrequency.')
        warning(' then call .calculate.')
        fields = NaN;
        return;
    end
        
    % ====================================================================
    %   CHOOSE APPROPRIATE FREQUENCY / ANGLE
    % =====================================================================
    
    % find the closest amplitudes
    [~, aidx] = findClosest(obj.angle, angleChoice);
    [~, fidx] = findClosest(obj.frequency, freqChoice);
    
    % assign closest frequency and angle
    freqVec = obj.frequency(fidx);
    angleVec = obj.angle(aidx);
    
    % print to screen the angle and frequency
%     disp(['Angle chosen: '      ,   num2str(angle_vec)    , 'degs'])
%     disp(['Frequency chosen: '  ,   num2str(freq_vec/1e6), ' MHz'])
    
    % output wave amplitudes from calculated model
    waveAmplitudes = (obj.unnormalised_amplitudes(fidx, aidx,:));   
    
    % =====================================================================
    %   PRECALCULATIONS
    % =====================================================================
    % final phase velocity
    phaseVel = sqrt(obj.medium(1).stiffness_matrix(1,1) / obj.medium(1).density);
    
    % the number of layers
    numLayers = length(obj.medium);
    
    % angle and phase velocity
    angle = angleVec;
    theta = angle * pi /180;
    % phase veloctids
    cp = phaseVel / sin(theta);
    % frequency
    omega = 2* pi * freqVec;
    k = omega / cp ;
    
    % incident wave amplitude set to 1 MPa
    P_0 = 1e6;
    B_1 =  (P_0 * 1i*k) / (obj.medium(1).density*omega^2);
    
%     waveAmplitudes = waveAmplitudes / ((P_0 * 1i*k) / (obj.medium(1).density*omega^2));
%     B_1 = 1;
    
    
    %% ====================================================================
    %   INTERFACE POSITIONS
    % =====================================================================
    
    % get the position of each interface, 0 is at the bottom halfspace interface
    cumulativeThickness = 0e-6;
    itfcPosition(numLayers-1) = cumulativeThickness;
    % loop over layers in the medium and extract thickness
    for intIdx = numLayers-1:-1:2
        % sum thicknesses apart from the 1 & N layers  (halfspaces)
        cumulativeThickness = cumulativeThickness + obj.medium(intIdx).thickness;
        % interface position
        itfcPosition(intIdx-1) = cumulativeThickness;
    end
    % set first boundary to be 0
    itfcPosition = itfcPosition - max(itfcPosition);
    
    %% ====================================================================
    %   DEFINE THE GRID
    % =====================================================================
    
    % choose number of samples
    zSamples = 256;
    xSamples = zSamples;
    
    % auto scale grid axes
    zSteps = linspace(-40*10^-6  + min(itfcPosition), ...
        40*10^-6   , zSamples);
    xSteps = linspace(-1/ cp   , 1/ cp     , xSamples);
    
    try
        % varargin{1} - grid data
        zSteps = varargin{1}{1};
        xSteps = varargin{1}{2};
        zSamples = length(zSteps);
        xSamples = length(xSteps);
        
        
    catch
        % error
        warning('Incorrect or no field input')
    end
    
    % define grid
    [Z , X] = (meshgrid(zSteps,xSteps));
    
    %% ====================================================================
    % GET THE SENSOR GEOMETRY - grid indices
    % =====================================================================
    
    % first find which layer the indices belong too
    
    % Show the image
    layer(1).idxs = find(Z >= itfcPosition(1));
    for ldx = 2:length(obj.medium)-1
        tmp = find(Z >= itfcPosition(ldx) & Z < itfcPosition(ldx-1));
        layer(ldx).idxs = tmp;
    end
    layer(length(obj.medium)).idxs = find(Z < itfcPosition(end));
    
    % check with an image
    myImage = zeros(size(Z));
    for ldx = 1:length(layer)
        myImage(layer(ldx).idxs) = ldx;
    end
    
    % plot geometry
    %{
    figure;
    % plot the figure
    imagesc(Zsteps,Xsteps,myImage)
    hold on
    plot(Z(layer(1).idxs),X(layer(1).idxs),'o')
    % labels
    title('Sensor Geometry')
    xlabel('Z - Depth')
    ylabel('X')
    %}
    
    % =============================================================
    %   MATERIAL PROPERTIES FOR EACH LAYER
    % =============================================================
    
    % loop over the medium layers and extract the important properties
    %   alpha - partial wave amplitudes
    %   C_mat - stiffness matrix for each material
    %   p_vec - polarisation of each partial wave
    for layIdx = 1:numLayers
        [ matProp(layIdx).alpha, matProp(layIdx).stiffness_matrix, matProp(layIdx).pVec ] = ...
            calculateAlphaCoefficients(...
            obj.medium(layIdx).stiffness_matrix, cp, obj.medium(layIdx).density );
    end
    
    % initalise displacement matrices
    x_displacement  = zeros(size(Z));
    z_displacement  = zeros(size(Z));
    normal_stress   = zeros(size(Z));
    shear_stress    = zeros(size(Z));
    
    % time/phase loop
    time = 0;
    try 
        time = varargin{2};
    end
        
    % time / phase loop
    for tdx = time
        % loop over the layers
        for layerIdx = 1:numLayers
            
            % the dx and dz steps
            dz1 = (Z(layer(layerIdx).idxs));
            dx1 = (X(layer(layerIdx).idxs));
            dz = reshape(dz1,xSamples,(length(dz1)/xSamples));
            dx = reshape(dx1,xSamples,(length(dz1)/xSamples));
            
            % common factor
     
            Psy = exp(1i * k * (dx - cp*tdx)) ;
            
            % fluid correction in first layer
            fCorr = 1;
            if matProp(layerIdx).stiffness_matrix(5,5) < 5
%                 disp('Corrected fluid')
                fCorr = 0; % remove shear components
            end
            
            stressNorm = 1i*k; 
            
            switch layerIdx
                case 1 
                    
                    % amplitude and z-phase
                    e1 = exp(1i * k * matProp(layerIdx).alpha(1) * dz) * waveAmplitudes(1) *fCorr;
                    e3 = exp(1i * k * matProp(layerIdx).alpha(3) * dz) * waveAmplitudes(2);
                    e4 = exp(1i * k * matProp(layerIdx).alpha(4) * dz) * B_1;
                    
                    % x-displacement
                    ux = Psy .* (e1 + e3 + e4) ;
                    % y-displacement
                    uz = Psy .* (...
                        e1 * matProp(layerIdx).pVec(1) + ...
                        e3 * matProp(layerIdx).pVec(3) + ...
                        e4 * matProp(layerIdx).pVec(4));
                    

                    % normal stress       
                    sigma_zz =  Psy .* stressNorm .* ( ...
                        e1 * (matProp(layerIdx).stiffness_matrix(1,3) + (matProp(layerIdx).stiffness_matrix(3,3)) * matProp(layerIdx).alpha(1) * matProp(layerIdx).pVec(1)) + ...
                        e3 * (matProp(layerIdx).stiffness_matrix(1,3) + (matProp(layerIdx).stiffness_matrix(3,3)) * matProp(layerIdx).alpha(3) * matProp(layerIdx).pVec(3)) + ...
                        e4 * (matProp(layerIdx).stiffness_matrix(1,3) + (matProp(layerIdx).stiffness_matrix(3,3)) * matProp(layerIdx).alpha(4) * matProp(layerIdx).pVec(4)) ) ;               
                    
                    % shear stress
                    st2 = matProp(layerIdx).stiffness_matrix(5, 5) * stressNorm; % a coefficient
                    sigma_xz =  Psy .* fCorr .* st2 .*(...
                        e1 * (matProp(layerIdx).alpha(1) + matProp(layerIdx).pVec(1)) + ...
                        e3 * (matProp(layerIdx).alpha(3) + matProp(layerIdx).pVec(3)) + ... 
                        e4 * (matProp(layerIdx).alpha(4) + matProp(layerIdx).pVec(4))) ;
                    
                    
                case numLayers
                    
                    % amplitude and z-phase
                    e2 = exp(1i * k * matProp(layerIdx).alpha(2) * dz) * waveAmplitudes(end-1) *fCorr;
                    e4 = exp(1i * k * matProp(layerIdx).alpha(4) * dz) * waveAmplitudes(end);
                    
                    % x-displacement
                    ux = Psy .* (e2 + e4) ;
                    % y-displacement
                    uz = Psy .* (...
                        e2 * matProp(layerIdx).pVec(2) + ...
                        e4 * matProp(layerIdx).pVec(4));         

                     % normal stress       
                    sigma_zz =  Psy .* stressNorm .* ( ...
                        e2 * (matProp(layerIdx).stiffness_matrix(1,3) + (matProp(layerIdx).stiffness_matrix(3,3)) * matProp(layerIdx).alpha(2) * matProp(layerIdx).pVec(2)) + ...
                        e4 * (matProp(layerIdx).stiffness_matrix(1,3) + (matProp(layerIdx).stiffness_matrix(3,3)) * matProp(layerIdx).alpha(4) * matProp(layerIdx).pVec(4)) ) ;               
                                        
                    % shear stress
                    st2 = matProp(layerIdx).stiffness_matrix(5, 5) * stressNorm; % a coefficient
                    sigma_xz =  Psy .* fCorr .* st2 .*(...
                        e2 * (matProp(layerIdx).alpha(2) + matProp(layerIdx).pVec(2)) + ...
                        e4 * (matProp(layerIdx).alpha(4) + matProp(layerIdx).pVec(4))) ;
                    
                    
                    
                otherwise
                    amp_idx = (layerIdx - 2)*4 + 2;
                    
                    % amplitude and z-phase
                    e1 = exp(1i * k * matProp(layerIdx).alpha(1) * dz) * waveAmplitudes(amp_idx + 1);
                    e2 = exp(1i * k * matProp(layerIdx).alpha(2) * dz) * waveAmplitudes(amp_idx + 2);
                    e3 = exp(1i * k * matProp(layerIdx).alpha(3) * dz) * waveAmplitudes(amp_idx + 3);
                    e4 = exp(1i * k * matProp(layerIdx).alpha(4) * dz) * waveAmplitudes(amp_idx + 4);
                    
                    % x-displacement
                    ux = Psy .* (e1 + e2 + e3 + e4) ;
                    % y-displacement
                    uz = Psy .* (...
                        e1 * matProp(layerIdx).pVec(1) + ...
                        e2 * matProp(layerIdx).pVec(2) + ...
                        e3 * matProp(layerIdx).pVec(3) + ...
                        e4 * matProp(layerIdx).pVec(4));
                    
                    % normal stress       
                    sigma_zz =   Psy .* stressNorm .* ( ...
                        e1 * (matProp(layerIdx).stiffness_matrix(1,3) + (matProp(layerIdx).stiffness_matrix(3,3)) * matProp(layerIdx).alpha(1) * matProp(layerIdx).pVec(1)) + ...
                        e2 * (matProp(layerIdx).stiffness_matrix(1,3) + (matProp(layerIdx).stiffness_matrix(3,3)) * matProp(layerIdx).alpha(2) * matProp(layerIdx).pVec(2)) + ...
                        e3 * (matProp(layerIdx).stiffness_matrix(1,3) + (matProp(layerIdx).stiffness_matrix(3,3)) * matProp(layerIdx).alpha(3) * matProp(layerIdx).pVec(3)) + ...
                        e4 * (matProp(layerIdx).stiffness_matrix(1,3) + (matProp(layerIdx).stiffness_matrix(3,3)) * matProp(layerIdx).alpha(4) * matProp(layerIdx).pVec(4)) ) ;               
                    
                    % shear stress
                    st2 = matProp(layerIdx).stiffness_matrix(5, 5) * stressNorm; % a coefficient
                    sigma_xz =  Psy .* fCorr .* st2 .*(...
                        e1 * (matProp(layerIdx).alpha(1) + matProp(layerIdx).pVec(1)) + ...
                        e2 * (matProp(layerIdx).alpha(2) + matProp(layerIdx).pVec(2)) + ...
                        e3 * (matProp(layerIdx).alpha(3) + matProp(layerIdx).pVec(3)) + ... 
                        e4 * (matProp(layerIdx).alpha(4) + matProp(layerIdx).pVec(4))) ;
                    
                    
                    
                    
            end
            
            % assign calculated values
            x_displacement(layer(layerIdx).idxs) = ux;
            z_displacement(layer(layerIdx).idxs) = uz;
            normal_stress(layer(layerIdx).idxs)  = sigma_zz;
            shear_stress(layer(layerIdx).idxs)   = sigma_xz;
            
        end % fields in each layer
        fields.xDisp    = x_displacement;
        fields.zDisp    = z_displacement;
        fields.zVec     = zSteps;
        fields.xVec     = xSteps;
        fields.sigZZ    = normal_stress;
        fields.sigXZ    = shear_stress;
        
    end % time loop
    
    
    
end