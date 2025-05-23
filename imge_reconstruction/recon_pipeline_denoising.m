% -_-_-_-_-_-_-_-_-_-_-_-_-_-_- recon_pipeline -_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-
%
% Description: 
% -----------
% 
% Reconstruction pipeline in Figure S2 of the Supporting Information of the
% paper used for reconstructing 3D MERMAID sequence.
% The raw data is in Siemens TWIX format, output of the 3D MERMAID
% sequence developed at MNI. More information:
% https://github.com/TardifLab/3D-MERMAID
%
% Assuming TWIX data is in /data/twix/, due to limited space on RAM data is
% reconstructed and sroted in /data/recon/tmp/ before the denoising step. 
% Final images are saved in /data/recon/.
% 
% NORDIC denoising adapted from github.com/SteenMoeller/NORDIC_Raw
%
% **It requries:
%               BART toolbox for image reconstruction (mrirecon.github.io/bart/) .
%
% Sample TWIX file can be found in https://doi.org/10.5683/SP3/ULKLNY
%
% Inputs:   TWIX file addresses in /data/twix/ directory.
% ------
% 
% Outputs:  saves reconstructed images as Nifti in /data/recon/ directory.
% -------
%       
% Article:  Feizollah and Tardif (2025), https://doi.org/10.1002/mrm.30436
% -------
% 
% Sajjad Feizollah, December 2024
% -_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-

data_address={
'/twix/meas_MID00305_FID13602_SF_mermaid_diff.dat'
    };

for i_data = 1: length(data_address)

    % vvvvvvvvvvvvvvv--selects and loads TWIX file--vvvvvvvvvvvvvvvvvvv
    clearvars -except data_address i_data
    recon_address = strfind(data_address{i_data},'twix/');
    fileName = strfind(data_address{i_data},'.');
    fileName = data_address{i_data}(recon_address(end)+5:fileName-1);
    recon_address = strcat(data_address{i_data}(1:recon_address(end)-1),'recon/');
    if(~isfolder(recon_address))
        mkdir(recon_address);
    end
    
    disp(newline+"Reading TWIX data...."+newline)
    twix=mapVBVD(data_address{i_data});
    twix=twix{2};   % usually image scan is the second RAID
    disp(newline+"Reading TWIX data....Done!")
    
    if(floor(twix.image.iceParam(21,1)/10) ~= 10)
        error(strcat('Sequence version not recognized!'));
    end
        
    %vvvvvvvvvvvv--extract parameters from reference scan header--vvvvvvvvvvvvv
    params.Ncol=twix.refscan.NCol;
    params.NpeRef=twix.hdr.Phoenix.sPat.lRefLinesPE;
    params.Rpe=twix.hdr.Phoenix.sPat.lAccelFactPE;
    params.Nproj=twix.hdr.Phoenix.sWipMemBlock.alFree{13};
    params.Nproj_total=twix.image.iceParam(13,1);
    params.Ncoil=twix.refscan.NCha;
    params.rotMatrix=quat2tform(twix.image.slicePos(4:end,1)');
    params.rotMatrix=params.rotMatrix(1:3,1:3);
    
    %vvvvvvvvvvvvvvvvvvvvvvv--user parameters--vvvvvvvvvvvvvvvvvvvvvvvvvvvv
    params.grappa_win=5;   % GRAPPA parameters
    params.grappa_line=2;
    params.grappa_tol=1e-4;
    
    params.doPOCS=false;   % POCS recon parameters for each projection
    params.itrPOCS=8;
    
    params.Rtri=0.25;     % triangle filter width
    
    params.fovOS=twix.hdr.Dicom.flReadoutOSFactor;    % FOV oversampling
    params.Nrecon=params.Ncol/params.fovOS;
    
    params.doHann=true;    % semi-Hanning window parameters
    params.HannPer=0.4;    % percentage of Hanning window cut-off frequency 
                           % (x2, 0.4 means 20%) 
    
    params.doMC=true;      % magnitude motion correction
    
    params.recon='CS';       % choose reconstruction method
                           %   '': SENSE
                           % 'L2': L2 norm regularization
                           % 'CS': compressed SENSE
    
    params.img_scale = 1e8; % scale of magnitude image when save as Nifti
    
    params.silent=true;    % show comments
    
    % vvvvvvvvvvvvvvvvvvvv--GRAPPA kernel estimation--vvvvvvvvvvvvvvvvvvvvv
    disp(newline+"================= reference scans =================")
    disp("GRAPPA weight estimation....")
    
    % nyquist ghost (N/2) correction of reference scans
    ref_data = ref_scan_nyquist_ghost_corr(twix);
        
    % generate index for GRAPPA kernel estimation
    [source_indx,target_indx] = ref_scan_GRAPPA_kernel_index(params);
    
    % calculate GRAPPA weights
    Wplane=ref_scan_GRAPPA_kernel_estimate(ref_data,source_indx,target_indx,params);
    disp(newline+"GRAPPA weight estimation....Done!")
    
    % clean up data
    clear ref_data source_indx target_indx
    disp("======================= Done! ======================")
    
    % vvvvvvvvvvv--Reconstruct projections of all volumes--vvvvvvvvvvvvvvvv
    % extract parameters from imaging scan header
    params.Ncol=twix.image.NCol;
    params.Nline=twix.image.NLin;
    params.Npe=twix.hdr.Config.PhaseEncodingLines;
    params.NpeRef=twix.hdr.Phoenix.sPat.lRefLinesPE;
    params.Rpe=twix.hdr.Phoenix.sPat.lAccelFactPE;
    params.Nproj=twix.hdr.Phoenix.sWipMemBlock.alFree{13};
    params.Nproj_total=twix.image.iceParam(13,1);
    params.Ncoil=twix.image.NCha;
    params.Nrep=twix.image.NRep;
    params.Ntrain=twix.hdr.Dicom.EchoTrainLength;
    params.Npf=params.Npe-params.Nline;
    params.NpadPf=floor(params.Npe/2) +1-twix.image.centerLin(1);
    
    % generate GRAPPA index for image recon
    [source_indx,target_indx] = imaging_scan_GRAPPA_imaging_index(twix,params);
    
    % generate triangle filter to remove phase
    filt = imaging_scan_generate_triangle_filter(params);
        
    % loop over volumes for reconstructing scans
    disp(newline+"============== reconstructing imaging volumes ==============")
    disp("Reconstructing all volumes....")
    fprintf("    reconstruct projections of all volumes....volume 000 of 000")
    if(~isfolder(strcat(recon_address,'/tmp/')))
        mkdir(strcat(recon_address,'/tmp/'));
    end
    
    % create files for each coil in /data/recon/tmp/
    for c=1:params.Ncoil
        if(i_data==1)
            RealfileID{c} = fopen(strcat(recon_address,'/tmp/','Rcoils',num2str(c),'.bin'), 'w');
            fclose(RealfileID{c});
            ImagefileID{c} = fopen(strcat(recon_address,'/tmp/','Icoils',num2str(c),'.bin'), 'w');
            fclose(ImagefileID{c});
        end
        RealfileID{c} = fopen(strcat(recon_address,'/tmp/','Rcoils',num2str(c),'.bin'), 'a+');
        ImagefileID{c} = fopen(strcat(recon_address,'/tmp/','Icoils',num2str(c),'.bin'), 'a+');
    end
    
    % reconstructs projections of all scans and coils
    for v=1:params.Nrep
        fprintf('\b\b\b\b\b\b\b\b\b\b%3d of %3d',v,params.Nrep)
        
        % extract b-value
        params.bvalue=twix.image.iceParam(7,(v-1)*twix.hdr.Dicom.EchoTrainLength*params.Nproj+1:twix.hdr.Dicom.EchoTrainLength*params.Nproj*v)-16384;
        params.bvalue=params.bvalue(1);
        
        % Nyquist ghost correction of scans
        data=imaging_scan_nyquist_ghost_corr(twix,v,params);
        
        % GRAPPA reconstruction of projections
        [im(:,:,:,1,:),im_filt(:,:,:,1,:)] = imaging_scan_GRAPPA_recon(twix,data,Wplane,source_indx,target_indx,filt,params);
        im_cor=abs(im).*exp(1i*(angle(im)-angle(im_filt)));
        for c=1:params.Ncoil
            fwrite(RealfileID{c},real(im_cor(:,:,:,:,c)),'single');
            fwrite(ImagefileID{c},imag(im_cor(:,:,:,:,c)),'single');
        end
    end
    for c=1:params.Ncoil
        fclose(ImagefileID{c});
        fclose(RealfileID{c});
    end

    % clean up
    clear data im_cor im im_filt ImagefileID RealfileID Wplane;
    fprintf("...Done!\n")
end

% vvvvvvvvvvvvvv--denoise projections over coil dimension--vvvvvvvvvvvvvvvv

fprintf("    denoising projections of each channel....coil 000 of 000")
% run denoising on each coil projections
ARG.temporal_phase=3;
ARG.phase_filter_width=3;
ARG.magnitude_only=0;
for c=1:params.Ncoil
    fprintf('\b\b\b\b\b\b\b\b\b\b%3d of %3d',c,params.Ncoil)
    RealfileID = fopen(strcat(recon_address,'/tmp/','Rcoils',num2str(c),'.bin'), 'r');
    ImagefileID = fopen(strcat(recon_address,'/tmp/','Icoils',num2str(c),'.bin'), 'r');
    im_cor = fread(RealfileID,'single')+1i*fread(ImagefileID,'single');
    im_cor = reshape(single(im_cor),params.Ncol,params.Npe,params.Nproj,[]);
    im_cor = MATLAB_NORDIC(im_cor,ARG);
    fclose(ImagefileID);
    fclose(RealfileID);
    RealfileID = fopen(strcat(recon_address,'/tmp/','Rcoils',num2str(c),'.bin'), 'w');
    ImagefileID = fopen(strcat(recon_address,'/tmp/','Icoils',num2str(c),'.bin'), 'w');
    fwrite(RealfileID,real(im_cor),'single');
    fwrite(ImagefileID,imag(im_cor),'single');
    fclose(ImagefileID);
    fclose(RealfileID);
end
clear im_cor RealfileID ImagefileID
fprintf("...Done!\n")

%% vvvvvvvvvvvv--reconstruct volumes from denoised projections--vvvvvvvvvvvv
for i_data = 1: length(data_address)
    clearvars -except data_address i_data params
    
    recon_address = strfind(data_address{i_data},'twix/');
    fileName = strfind(data_address{i_data},'.');
    fileName = data_address{i_data}(recon_address(end)+5:fileName-1);
    recon_address = strcat(data_address{i_data}(1:recon_address(end)-1),'recon/');
    
    disp(newline+"Reading TWIX data...."+newline)
    twix=mapVBVD(data_address{i_data});
    disp(newline+"Reading TWIX data....Done!")
    twix=twix{2};   % usually image scan is the second RAID
        
    % extract parameters from reference scan header
    params.Ncol=twix.refscan.NCol;
    params.NpeRef=twix.hdr.Phoenix.sPat.lRefLinesPE;
    params.Rpe=twix.hdr.Phoenix.sPat.lAccelFactPE;
    params.Nproj=twix.hdr.Phoenix.sWipMemBlock.alFree{13};
    params.Nproj_total=twix.image.iceParam(13,1);
    params.Ncoil=twix.refscan.NCha;
    params.rotMatrix=quat2tform(twix.image.slicePos(4:end,1)');
    params.rotMatrix=params.rotMatrix(1:3,1:3);
    params.silent=false;
    
    % coil sensitivity estimation
    disp(newline+"================= reference scans =================")
    
    % nyquist ghost correction of reference scans
    ref_data = ref_scan_nyquist_ghost_corr(twix);
   
    disp("estimate coil sensitivity....")
    
    % create low-pass filter to remove phase
    filt=ref_scan_generate_triangle_filter(params);
    
    % remove phase from each projection
    ref_kdata_cor=ref_scan_remove_phase(ref_data,filt,params);
    
    % zeropad over the PE direction
    ref_kdata_cor=padarray(ref_kdata_cor,[0,(params.Npe-params.NpeRef)/2,0,0],'both');
    ref_kdata_cor=ref_kdata_cor.*reshape(hann(params.Npe),1,[],1,1);
    
    % iFFT over PE direction
    fprintf("    iFFT in phase-encode....projection 000 of 000")
    for p=1:size(ref_kdata_cor,3)
        fprintf('\b\b\b\b\b\b\b\b\b\b%3d of %3d',p,params.Nproj)
        ref_kdata_cor(:,:,p,:)=fftshift(ifft(fftshift(ref_kdata_cor(:,:,p,:)),[],2));
    end
    fprintf("...Done!\n")
    
    % generate in-plane radial trajectory
    traj=ref_scan_generate_trajectory(params);
    
    % estimate coil sensitivity maps
    sens_map=ref_scan_coil_map_estimate(ref_kdata_cor,traj,params);
    
    % clean up data
    clear ref_data ref_kdata_cor traj filt
    disp("======================= Done! ======================")
    
    % extract parameters from imaging scan header
    params.Ncol=twix.image.NCol;
    params.Nline=twix.image.NLin;
    params.Npe=twix.hdr.Config.PhaseEncodingLines;
    params.NpeRef=twix.hdr.Phoenix.sPat.lRefLinesPE;
    params.Rpe=twix.hdr.Phoenix.sPat.lAccelFactPE;
    params.Nproj=twix.hdr.Phoenix.sWipMemBlock.alFree{13};
    params.Nproj_total=twix.image.iceParam(13,1);
    params.Ncoil=twix.image.NCha;
    params.Nrep=twix.image.NRep;
    params.Ntrain=twix.hdr.Dicom.EchoTrainLength;
    params.Npf=params.Npe-params.Nline;
    params.NpadPf=floor(params.Npe/2) +1-twix.image.centerLin(1);
    params.Nvol(i_data)=twix.image.NRep;
    
    img=zeros(params.Npe,params.Nrecon,params.Nrecon,params.Nrep);
    blockSize = params.Ncol*params.Npe*params.Nproj;
    elementSize = 4;
    img_cor_denoise = zeros(params.Ncol,params.Npe,params.Nproj,params.Ncoil);
    
    % generate semi-Hanning filter to remove ringing
    filtHann=imaging_scan_generate_Hanning(params);
    
    for v=1:params.Nrep
        disp("Reconstructing volumes " + v + " of " + params.Nrep + "....")
        
        for c=1:params.Ncoil
            RealfileID = fopen(strcat(recon_address,'/tmp/','Rcoils',num2str(c),'.bin'), 'r');
            ImagefileID = fopen(strcat(recon_address,'/tmp/','Icoils',num2str(c),'.bin'), 'r');
            fseek(RealfileID, (v-1+sum(params.Nvol(1:i_data-1)))*blockSize*elementSize, 'bof');
            fseek(ImagefileID, (v-1+sum(params.Nvol(1:i_data-1)))*blockSize*elementSize, 'bof');
            tmp = fread(RealfileID,blockSize,'single')+1i*fread(ImagefileID,blockSize,'single');
            img_cor_denoise(:,:,:,c) = reshape(single(tmp),params.Ncol,params.Npe,params.Nproj);
            fclose(ImagefileID);
            fclose(RealfileID);
        end
        
        % extract b-value
        params.bvalue=twix.image.iceParam(7,(v-1)*twix.hdr.Dicom.EchoTrainLength*params.Nproj+1:twix.hdr.Dicom.EchoTrainLength*params.Nproj*v)-16384;
        params.bvalue=params.bvalue(1);
       
        % resample projections into k-space
        fprintf("    resample into k-space....projection 000 of 000")
        kdata_cor=single(zeros([params.Ncol,params.Npe,params.Nproj,params.Ncoil]));
        for p=1:params.Nproj
            fprintf('\b\b\b\b\b\b\b\b\b\b%3d of %3d',p,params.Nproj)
            kdata_cor(:,:,p,:)=fftshift(fft2(fftshift(squeeze(img_cor_denoise(:,:,p,:)))));
        end
        fprintf("...Done!\n")
        
        % apply Hanning filter
        if(params.doHann)
            kdata_cor=kdata_cor.*filtHann;
        end
        
        % magnitude phase correction
        [kdata_cor,ind_mc] = imaging_scan_magnitude_motion_corr(kdata_cor,img_cor_denoise,params);
        clear im_cor
        
        % Cartesian FFT over PE direction
        fprintf("    iFFT in phase-encode....projection 000 of 000")
        for p=1:size(kdata_cor,3)
            fprintf('\b\b\b\b\b\b\b\b\b\b%3d of %3d',p,params.Nproj)
            kdata_cor(:,:,p,:)=fftshift(ifft(fftshift(kdata_cor(:,:,p,:)),[],2));
        end
        fprintf("...Done!\n")
        
        % generate in-plane radial trajectory
        traj = imaging_scan_generate_trajectory(twix,ind_mc,params);        
        
        % nonuniform FFT of each PE plane
        img(:,:,:,v) = imaging_scan_radial_recon(kdata_cor,traj,sens_map,params);
        
    end
    
    img=img(:,(params.Nrecon-params.Ncol/2)/2+1:params.Npe+(params.Nrecon-params.Ncol/2)/2,(params.Nrecon-params.Ncol/2)+1:end,:);
    
    % save data to nifti
    save_nifti(abs(img)*params.img_scale,twix,strcat(recon_address, fileName, '_mag.nii'));
    save_nifti(angle(img),twix,strcat(recon_address, fileName, '_phase.nii'));
    
    disp("=========================== Done! ==========================")
end
